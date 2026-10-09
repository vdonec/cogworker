# frozen_string_literal: true

module Cogworker
  # What becomes of a failed attempt: `retry` (after `delay` seconds — nil
  # for the default backoff), `dead` or `discard`. Made once per failure:
  # by the job class's `cogworker_retry_in` hook where it has one, otherwise
  # by the retry budget and the default backoff.
  #
  # `Processor` makes it inside the middleware chain, the moment `perform`
  # raises, and (when a hook took part) stamps it on the job as
  # `failure_outcome` so `JobUtil.terminal_failure?` — and with it Status,
  # UniqueJobs and Periodic middleware — gives the same answer as the
  # retry/dead write. The stamp never reaches a stored entry.
  class FailureDecision
    OUTCOMES = %w[retry dead discard].freeze
    # Used as given, never capped — but a delay past this is most likely a
    # unit mix-up (ms for s), and it keeps an `until_executed` lock that long.
    LONG_DELAY = 365 * 24 * 60 * 60

    attr_reader :outcome, :delay

    class << self
      # `for`, stamped on the job as `failure_outcome` when the class's hook
      # took part (see the class comment). nil if deciding itself failed.
      def decide!(job, error, klass)
        decision = self.for(job, error, klass)
        job['failure_outcome'] = decision.outcome if decision.hooked?
        decision
      rescue StandardError => e
        Cogworker.logger.error { "couldn't decide the fate of jid=#{job['jid']}: #{e.class}: #{e.message}" }
        nil
      end

      # `klass` — the job's class, or nil when it couldn't be resolved (no
      # hook then). The hook isn't asked about a failure that is the last
      # one anyway: there's no retry to time.
      def for(job, error, klass)
        count = job['retry_count'].to_i
        return new('dead') if count + 1 > JobUtil.max_retries(job)

        hook = klass.respond_to?(:cogworker_retry_in_block) ? klass.cogworker_retry_in_block : nil
        return new('retry') unless hook

        from_hook(hook, job, error, count)
      end

      # Grows with the retry count, with jitter to avoid a thundering herd
      # of retries all landing on the same second.
      def default_delay(count)
        (count**4) + 15 + (rand(30) * (count + 1))
      end

      private

      def from_hook(hook, job, error, count)
        value = JobUtil.call_hook(hook, count, error, JobUtil.deep_copy(job))
        case value
        when nil then new('retry', hooked: true)
        when :kill then new('dead', killed: true, hooked: true)
        when :discard then new('discard', hooked: true)
        else
          if valid_delay?(value)
            warn_long_delay(job, value) if value > LONG_DELAY
            return new('retry', value, hooked: true)
          end

          Cogworker.logger.warn do
            "cogworker_retry_in of #{job['class']} returned #{value.inspect} for jid=#{job['jid']}; " \
              'using the default backoff'
          end
          new('retry', hooked: true)
        end
      rescue Exception => e # rubocop:disable Lint/RescueException -- user code, isolated like `perform`
        Cogworker.logger.error do
          "cogworker_retry_in of #{job['class']} raised for jid=#{job['jid']} (using the default backoff): " \
            "#{e.class}: #{JobUtil.error_message(e)}"
        end
        new('retry', hooked: true)
      end

      def warn_long_delay(job, value)
        Cogworker.logger.warn do
          "cogworker_retry_in of #{job['class']} returned #{value}s (over a year) for jid=#{job['jid']}; " \
            'using it as given'
        end
      end

      def valid_delay?(value)
        (value.is_a?(Integer) || (value.is_a?(Float) && value.finite?)) && value >= 0
      end
    end

    def initialize(outcome, delay = nil, killed: false, hooked: false)
      @outcome = outcome
      @delay = delay
      @killed = killed
      @hooked = hooked
    end

    def retry?
      outcome == 'retry'
    end

    def dead?
      outcome == 'dead'
    end

    def discard?
      outcome == 'discard'
    end

    # Whether the job class's hook took part (only then is the decision
    # stamped on the job: without one, `terminal_failure?` already agrees).
    def hooked?
      @hooked
    end

    # Ended before its retries ran out: `:kill`, or `:discard`.
    def cut_short?
      @killed || discard?
    end

    # The outcome as the attempts log (and the Web UI's timeline) shows it.
    def attempt_outcome
      return 'retrying' if retry?
      return 'discarded' if discard?

      @killed ? 'killed' : 'dead'
    end
  end
end
