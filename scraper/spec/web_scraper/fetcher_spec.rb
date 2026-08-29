# frozen_string_literal: true

require "spec_helper"
require "httparty"
require "stringio"
require_relative "../../lib/web_scraper/fetcher"
require_relative "../../lib/web_scraper/rate_limiter"

RSpec.describe WebScraper::Fetcher do
  let(:rate_limiter) { instance_double(WebScraper::RateLimiter, throttle!: nil) }
  let(:sleeper) { instance_double(Proc, call: nil) }
  let(:log) { StringIO.new }

  def build_fetcher(http_client:, retries: 3)
    described_class.new(
      retries: retries,
      timeout: 5,
      rate_limiter: rate_limiter,
      http_client: http_client,
      sleeper: sleeper,
      logger: log
    )
  end

  def fake_response(code:, body: "<html><title>OK</title></html>")
    instance_double(HTTParty::Response, code: code, body: body)
  end

  describe "#fetch" do
    it "returns an extracted record on a successful first attempt" do
      http = class_double(HTTParty)
      allow(http).to receive(:get).and_return(fake_response(code: 200))

      fetcher = build_fetcher(http_client: http)
      result = fetcher.fetch("https://example.com")

      expect(result["url"]).to eq("https://example.com")
      expect(result["title"]).to eq("OK")
      expect(result["status_code"]).to eq(200)
      expect(result["error"]).to be_nil
      expect(rate_limiter).to have_received(:throttle!).once
    end

    it "retries on a raised network error and succeeds on a later attempt" do
      http = class_double(HTTParty)
      call_count = 0
      allow(http).to receive(:get) do
        call_count += 1
        raise Timeout::Error, "timed out" if call_count == 1

        fake_response(code: 200)
      end

      fetcher = build_fetcher(http_client: http, retries: 3)
      result = fetcher.fetch("https://example.com")

      expect(result["error"]).to be_nil
      expect(call_count).to eq(2)
      expect(sleeper).to have_received(:call).once
    end

    it "retries on a retryable 500 status" do
      http = class_double(HTTParty)
      allow(http).to receive(:get).and_return(fake_response(code: 500), fake_response(code: 200))

      fetcher = build_fetcher(http_client: http, retries: 2)
      result = fetcher.fetch("https://example.com")

      expect(result["status_code"]).to eq(200)
      expect(result["error"]).to be_nil
    end

    it "gives up after exhausting all retries and returns an error record" do
      http = class_double(HTTParty)
      allow(http).to receive(:get).and_raise(Timeout::Error, "timed out")

      fetcher = build_fetcher(http_client: http, retries: 2)
      result = fetcher.fetch("https://example.com/down")

      expect(result["error"]).to include("Timeout::Error")
      expect(result["retries"]).to eq(2)
      expect(result["status_code"]).to be_nil
      expect(sleeper).to have_received(:call).twice
    end

    it "throttles before every attempt, including retries" do
      http = class_double(HTTParty)
      call_count = 0
      allow(http).to receive(:get) do
        call_count += 1
        raise Timeout::Error, "timed out" if call_count == 1

        fake_response(code: 200)
      end

      fetcher = build_fetcher(http_client: http, retries: 1)
      fetcher.fetch("https://example.com")

      expect(rate_limiter).to have_received(:throttle!).twice
    end
  end
end
