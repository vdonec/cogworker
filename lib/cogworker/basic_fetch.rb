# frozen_string_literal: true

module Cogworker
  # Pops jobs off Redis lists. Queue names repeated in the process's queue
  # list represent weight; since BRPOP itself scans its key list
  # strictly left-to-right, weighting is implemented by shuffling the
  # (already-expanded, so repeats survive) key list before every fetch cycle
  # — the more often a name appears, the more likely it lands first.
  class BasicFetch
    TIMEOUT = 2 # seconds; also how often a stopped/quieted processor notices and exits its fetch loop.

    def initialize(queues)
      @queue_keys = Array(queues).map { |q| RedisKeys.queue(q) }
    end

    # Re-reads `cogworker:paused_queues` on every single fetch (not once at
    # `initialize`, and not cached) — a `Queue#pause!`/`#resume!` from the
    # Web UI takes effect on this processor's very next cycle, not just for
    # ones started after the toggle. If every one of this processor's
    # queues is currently paused, there's nothing left to `BRPOP` at all
    # (an empty key list is invalid) — sleep out one `TIMEOUT` instead of
    # returning immediately, same pause `BRPOP` itself would have caused,
    # so `Processor#run`'s loop doesn't spin hot polling Redis in a tight
    # loop with no rate limit.
    def retrieve_work
      keys = active_keys
      if keys.empty?
        sleep(TIMEOUT)
        return nil
      end

      result = Cogworker.config.redis { |c| c.brpop(*keys.shuffle, timeout: TIMEOUT) }
      return nil unless result

      queue_key, raw_job = result
      UnitOfWork.new(queue_key.delete_prefix(RedisKeys::QUEUE_PREFIX), raw_job)
    end

    private

    def active_keys
      paused = Cogworker.config.redis { |c| c.smembers(RedisKeys::PAUSED_QUEUES) }
      return @queue_keys if paused.empty?

      @queue_keys.reject { |k| paused.include?(k.delete_prefix(RedisKeys::QUEUE_PREFIX)) }
    end

    UnitOfWork = Struct.new(:queue, :raw_job)
  end
end
