# frozen_string_literal: true

require "time"

module WebScraper
  # Pulls structured fields out of a parsed Nokogiri document. Kept free of
  # any network or IO concerns so it can be unit tested with plain HTML
  # strings -- see spec/web_scraper/extractor_spec.rb.
  module Extractor
    module_function

    # @param url [String] the URL that was fetched (echoed back verbatim)
    # @param doc [Nokogiri::HTML::Document]
    # @param status_code [Integer]
    # @param body_bytesize [Integer]
    # @return [Hash] a JSON-serializable record matching the schema consumed
    #   by WebScraper.Types.ScrapedPage on the Haskell side.
    def extract(url:, doc:, status_code:, body_bytesize:)
      {
        "url" => url,
        "status_code" => status_code,
        "title" => clean(doc.at_css("title")&.text),
        "meta_description" => clean(meta_description(doc)),
        "headings" => headings(doc),
        "word_count" => word_count(doc),
        "content_length" => body_bytesize,
        "scraped_at" => Time.now.utc.iso8601,
        "retries" => 0,
        "error" => nil
      }
    end

    # Builds the JSON record for a URL that could not be fetched at all,
    # after every retry has been exhausted.
    def error_record(url:, error_message:, retries:, status_code: nil)
      {
        "url" => url,
        "status_code" => status_code,
        "title" => nil,
        "meta_description" => nil,
        "headings" => [],
        "word_count" => nil,
        "content_length" => nil,
        "scraped_at" => Time.now.utc.iso8601,
        "retries" => retries,
        "error" => error_message
      }
    end

    def meta_description(doc)
      doc.at_css('meta[name="description"]')&.attr("content") ||
        doc.at_css('meta[property="og:description"]')&.attr("content")
    end

    def headings(doc)
      doc.css("h1, h2, h3").map { |node| clean(node.text) }.reject(&:empty?)
    end

    def word_count(doc)
      doc.text.split(/\s+/).reject(&:empty?).size
    end

    # Collapses whitespace and trims -- mirrors WebScraper.Processing.cleanText
    # on the Haskell side, though Haskell re-cleans everything anyway, so
    # this just keeps the raw payload tidy for anyone reading it directly.
    def clean(text)
      return "" if text.nil?

      text.gsub(/\s+/, " ").strip
    end
  end
end
