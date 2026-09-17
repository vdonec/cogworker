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

    def retrieve_work
      keys = @queue_keys.shuffle
      result = Cogworker.config.redis { |c| c.brpop(*keys, timeout: TIMEOUT) }
      return nil unless result

      queue_key, raw_job = result
      UnitOfWork.new(queue_key.delete_prefix(RedisKeys::QUEUE_PREFIX), raw_job)
    end

    UnitOfWork = Struct.new(:queue, :raw_job)
  end
end
