#!/usr/bin/env ruby
# frozen_string_literal: true

# WebScraper Ruby worker.
#
# Reads a list of URLs from STDIN (one per line, blank lines and lines
# starting with '#' are ignored), scrapes each one with Nokogiri + HTTParty
# (retrying transient failures and respecting a rate limit), and writes one
# JSON object per line (NDJSON) to STDOUT as each result completes.
#
# This script never talks to SQLite or does any "processing" beyond raw
# extraction -- that's deliberately left to the Haskell side. It is spawned
# and driven by the Haskell orchestrator (see src/WebScraper/Scraper.hs),
# but can also be run and piped to by hand:
#
#   printf "https://example.com\nhttps://example.org\n" | \
#     ruby scraper/scraper.rb --rate-limit 2.0 --retries 3

require "httparty"
require "json"
require "optparse"

require_relative "lib/web_scraper/extractor"
require_relative "lib/web_scraper/rate_limiter"
require_relative "lib/web_scraper/fetcher"

module WebScraper
  # Wires the CLI together: parses flags, reads STDIN, drives a Fetcher for
  # each URL, and streams NDJSON to STDOUT.
  class CLI
    DEFAULT_RATE_LIMIT = 2.0
    DEFAULT_RETRIES = 3
    DEFAULT_TIMEOUT = 10

    def self.run(argv, stdin: $stdin, stdout: $stdout, stderr: $stderr)
      options = parse_options(argv)

      rate_limiter = RateLimiter.new(options[:rate_limit])
      fetcher = Fetcher.new(
        retries: options[:retries],
        timeout: options[:timeout],
        rate_limiter: rate_limiter,
        logger: stderr
      )

      urls = read_urls(stdin)
      stderr.puts("[#{Time.now.utc.iso8601}] INFO  scraper worker starting: #{urls.size} URL(s), " \
                  "rate_limit=#{options[:rate_limit]}, retries=#{options[:retries]}")

      urls.each do |url|
        result = fetcher.fetch(url)
        stdout.puts(JSON.generate(result))
        stdout.flush
      end

      stderr.puts("[#{Time.now.utc.iso8601}] INFO  scraper worker finished")
    end

    def self.parse_options(argv)
      options = {
        rate_limit: DEFAULT_RATE_LIMIT,
        retries: DEFAULT_RETRIES,
        timeout: DEFAULT_TIMEOUT
      }

      OptionParser.new do |opts|
        opts.banner = "Usage: scraper.rb [options] < urls.txt"

        opts.on("--rate-limit RATE", Float, "Requests per second (default: #{DEFAULT_RATE_LIMIT})") do |v|
          options[:rate_limit] = v
        end

        opts.on("--retries N", Integer, "Retry attempts per URL (default: #{DEFAULT_RETRIES})") do |v|
          options[:retries] = v
        end

        opts.on("--timeout SECONDS", Integer, "Per-request timeout in seconds (default: #{DEFAULT_TIMEOUT})") do |v|
          options[:timeout] = v
        end
      end.parse!(argv)

      options
    end

    def self.read_urls(stdin)
      stdin.each_line.map(&:strip).reject { |line| line.empty? || line.start_with?("#") }
    end
  end
end

WebScraper::CLI.run(ARGV) if $PROGRAM_NAME == __FILE__
