# frozen_string_literal: true

require "spec_helper"
require "nokogiri"
require_relative "../../lib/web_scraper/extractor"

RSpec.describe WebScraper::Extractor do
  let(:html) do
    <<~HTML
      <html>
        <head>
          <title>  My Test Page  </title>
          <meta name="description" content="A page about testing.">
        </head>
        <body>
          <h1>Welcome</h1>
          <p>Some body text with a few words in it.</p>
          <h2>Section One</h2>
          <h3></h3>
        </body>
      </html>
    HTML
  end
  let(:doc) { Nokogiri::HTML(html) }

  describe ".extract" do
    subject(:result) { described_class.extract(url: "https://example.com", doc: doc, status_code: 200, body_bytesize: 1234) }

    it "echoes back the url" do
      expect(result["url"]).to eq("https://example.com")
    end

    it "cleans the title" do
      expect(result["title"]).to eq("My Test Page")
    end

    it "extracts the meta description" do
      expect(result["meta_description"]).to eq("A page about testing.")
    end

    it "collects non-empty headings in document order" do
      expect(result["headings"]).to eq(["Welcome", "Section One"])
    end

    it "counts words in the document text" do
      expect(result["word_count"]).to be > 0
    end

    it "passes through status code and content length" do
      expect(result["status_code"]).to eq(200)
      expect(result["content_length"]).to eq(1234)
    end

    it "stamps an ISO8601 scraped_at timestamp" do
      expect { Time.iso8601(result["scraped_at"]) }.not_to raise_error
    end

    it "has no error" do
      expect(result["error"]).to be_nil
    end
  end

  describe ".error_record" do
    subject(:result) { described_class.error_record(url: "https://example.com/down", error_message: "Timeout::Error: timed out", retries: 3) }

    it "carries the error message and retry count" do
      expect(result["error"]).to eq("Timeout::Error: timed out")
      expect(result["retries"]).to eq(3)
    end

    it "leaves content fields nil/empty" do
      expect(result["title"]).to be_nil
      expect(result["headings"]).to eq([])
    end
  end

  describe ".clean" do
    it "collapses whitespace" do
      expect(described_class.clean("a   b\n\tc")).to eq("a b c")
    end

    it "returns an empty string for nil" do
      expect(described_class.clean(nil)).to eq("")
    end
  end
end
