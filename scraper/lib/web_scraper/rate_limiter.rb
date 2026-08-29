# frozen_string_literal: true

module WebScraper
  # A simple token-pacing rate limiter: sleeps just long enough before each
  # request to keep the long-run average at +requests_per_second+. This
  # process only ever handles its own chunk of URLs -- the Haskell
  # orchestrator divides the global --rate-limit budget across however many
  # scraper processes it spawns, so each instance just needs to behave
  # correctly on its own.
  class RateLimiter
    def initialize(requests_per_second)
      raise ArgumentError, "requests_per_second must be positive" unless requests_per_second.positive?

      @min_interval = 1.0 / requests_per_second
      @last_request_at = nil
    end

    # Blocks (if necessary) so that calls are spaced at least
    # +@min_interval+ seconds apart.
    def throttle!
      now = monotonic_now
      if @last_request_at
        elapsed = now - @last_request_at
        wait = @min_interval - elapsed
        sleep(wait) if wait.positive?
      end
      @last_request_at = monotonic_now
    end

    private

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
