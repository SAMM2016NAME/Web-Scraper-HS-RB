# frozen_string_literal: true

require "httparty"
require "nokogiri"
require "time"

require_relative "extractor"

module WebScraper
  # Fetches one URL with retry + rate limiting, and turns the result into a
  # JSON-serializable record via Extractor. All collaborators (HTTP client,
  # rate limiter, sleeper, logger) are injectable so this class can be unit
  # tested without hitting the network or actually sleeping -- see
  # spec/web_scraper/fetcher_spec.rb.
  class Fetcher
    class FetchError < StandardError; end

    USER_AGENT = "WebScraper/0.1 (+https://github.com/yourname/web-scraper-hs-rb)"
    RETRYABLE_STATUSES = ((500..599).to_a + [429]).freeze

    def initialize(retries:, timeout:, rate_limiter:, http_client: HTTParty, sleeper: ->(s) { Kernel.sleep(s) }, logger: $stderr)
      @retries = retries
      @timeout = timeout
      @rate_limiter = rate_limiter
      @http_client = http_client
      @sleeper = sleeper
      @logger = logger
    end

    # @return [Hash] always returns a well-formed record, even on total
    #   failure -- callers never need to rescue anything from here.
    def fetch(url)
      attempt = 0

      loop do
        @rate_limiter.throttle!

        begin
          response = @http_client.get(url, timeout: @timeout, headers: { "User-Agent" => USER_AGENT })
          raise FetchError, "HTTP #{response.code}" if RETRYABLE_STATUSES.include?(response.code)

          body = response.body.to_s
          doc = Nokogiri::HTML(body)
          return WebScraper::Extractor.extract(url: url, doc: doc, status_code: response.code, body_bytesize: body.bytesize)
        rescue StandardError => e
          if attempt < @retries
            attempt += 1
            backoff = 2**attempt
            log(:warn, "retry #{attempt}/#{@retries} for #{url} after #{e.class}: #{e.message} -- backing off #{backoff}s")
            @sleeper.call(backoff)
          else
            log(:error, "giving up on #{url} after #{attempt} retr#{attempt == 1 ? 'y' : 'ies'}: #{e.class}: #{e.message}")
            return WebScraper::Extractor.error_record(url: url, error_message: "#{e.class}: #{e.message}", retries: attempt)
          end
        end
      end
    end

    private

    def log(level, message)
      ts = Time.now.utc.iso8601
      @logger.puts("[#{ts}] #{level.to_s.upcase.ljust(5)} #{message}")
    end
  end
end
