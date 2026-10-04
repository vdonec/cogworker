# frozen_string_literal: true

module Cogworker
  # Telling "Redis is unavailable right now" from every other error, and
  # keeping the log readable while it is.
  #
  # Unavailable means a lost connection, or one of the replies a server
  # gives while it can't serve writes for a while — mid-failover (READONLY,
  # MASTERDOWN), still loading its data (LOADING), or busy with a script
  # (BUSY, TRYAGAIN). None of those say anything about the job, entry or key
  # being worked on, so nothing should back off, count a failure, or give up
  # on them; they just mean "try again shortly".
  #
  # `report` logs such errors once per `site` (a short name of the place
  # they come from) as they start, then a one-line summary at most every
  # SUMMARY_INTERVAL, and `recovered(site)` logs once that it's over. A 6
  # minute outage used to produce thousands of identical lines. Any other
  # error is logged in full, every time.
  module RedisErrors
    UNAVAILABLE_REPLIES = %w[READONLY LOADING MASTERDOWN TRYAGAIN BUSY].freeze
    SUMMARY_INTERVAL = 60
    SCRIPT_WRAPPED = /-(?:#{UNAVAILABLE_REPLIES.join('|')})(?=\s|\z)/

    @mutex = Mutex.new
    @outages = {} # site => { count:, since:, summarized_at:, error: }

    class << self
      def unavailable?(error)
        return true if error.is_a?(Redis::BaseConnectionError)
        # redis-rb 5's pub/sub path can surface redis-client's own error class.
        return true if defined?(RedisClient::ConnectionError) && error.is_a?(RedisClient::ConnectionError)

        return false unless error.is_a?(Redis::CommandError)

        message = error.message.to_s
        # The reply's code is its whole first word — BUSYKEY or BUSYGROUP
        # aren't BUSY. Inside a script, Redis 6.x wraps the code instead:
        # "ERR Error running script (...): ... -READONLY You can't ...".
        UNAVAILABLE_REPLIES.include?(message[/\A\S+/]) ||
          (message.include?('Error running script') && message.match?(SCRIPT_WRAPPED))
      end

      # Logs `error` at `site`; the block, if given, adds context to the
      # first line (e.g. what was being done).
      def report(site, error, &context)
        detail = "#{error.class}: #{error.message}"
        detail = "#{context.call} — #{detail}" if context
        return Cogworker.logger.error { "#{site}: #{detail}" } unless unavailable?(error)

        line = @mutex.synchronize { track(site, error, detail) }
        Cogworker.logger.error { line } if line
      end

      # Call wherever `site` has just done its job: ends an outage there.
      def recovered(site)
        outage = @mutex.synchronize { @outages.delete(site) }
        return unless outage

        Cogworker.logger.warn do
          "#{site}: Redis available again after #{outage[:count]} error(s) over #{(now - outage[:since]).round}s"
        end
      end

      def reset!
        @mutex.synchronize { @outages.clear }
      end

      private

      def track(site, error, detail)
        outage = @outages[site]
        unless outage
          @outages[site] = { count: 1, since: now, summarized_at: now, suppressed: 0 }
          return "#{site}: Redis unavailable — #{detail} (repeats summarized every #{SUMMARY_INTERVAL}s)"
        end

        outage[:count] += 1
        outage[:suppressed] += 1
        return unless now - outage[:summarized_at] >= SUMMARY_INTERVAL

        suppressed = outage[:suppressed]
        outage[:summarized_at] = now
        outage[:suppressed] = 0
        "#{site}: Redis still unavailable — #{suppressed} more error(s) in the last #{SUMMARY_INTERVAL}s " \
          "(latest: #{error.class}: #{error.message})"
      end

      def now
        ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
      end
    end
  end
end
