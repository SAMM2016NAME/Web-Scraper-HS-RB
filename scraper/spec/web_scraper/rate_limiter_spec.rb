# frozen_string_literal: true

require "spec_helper"
require_relative "../../lib/web_scraper/rate_limiter"

RSpec.describe WebScraper::RateLimiter do
  describe "#initialize" do
    it "rejects a non-positive rate" do
      expect { described_class.new(0) }.to raise_error(ArgumentError)
      expect { described_class.new(-1) }.to raise_error(ArgumentError)
    end
  end

  describe "#throttle!" do
    it "does not sleep on the first call" do
      limiter = described_class.new(10)
      expect(limiter).not_to receive(:sleep)
      limiter.throttle!
    end

    it "sleeps for approximately the remaining interval when called too soon" do
      limiter = described_class.new(2) # min_interval = 0.5s
      limiter.instance_variable_set(:@last_request_at, Process.clock_gettime(Process::CLOCK_MONOTONIC))

      expect(limiter).to receive(:sleep) do |seconds|
        expect(seconds).to be > 0
        expect(seconds).to be <= 0.5
      end
      limiter.throttle!
    end

    it "does not sleep when calls are already spaced out enough" do
      limiter = described_class.new(1) # min_interval = 1.0s
      limiter.instance_variable_set(:@last_request_at, Process.clock_gettime(Process::CLOCK_MONOTONIC) - 5)

      expect(limiter).not_to receive(:sleep)
      limiter.throttle!
    end
  end
end
