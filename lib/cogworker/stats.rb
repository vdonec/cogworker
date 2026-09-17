# frozen_string_literal: true

module Cogworker
  # Aggregate counters. Cheap: a handful of GET/ZCARD/LLEN calls, no keyspace
  # scanning.
  class Stats
    def enqueued
      queue_names.sum { |q| Cogworker.config.redis { |c| c.llen(RedisKeys.queue(q)) } }
    end

    def processed
      (Cogworker.config.redis { |c| c.get(RedisKeys::STATS_PROCESSED) } || 0).to_i
    end

    def failed
      (Cogworker.config.redis { |c| c.get(RedisKeys::STATS_FAILED) } || 0).to_i
    end

    def retry_size
      Cogworker.config.redis { |c| c.zcard(RedisKeys::RETRY) }
    end

    def scheduled_size
      Cogworker.config.redis { |c| c.zcard(RedisKeys::SCHEDULE) }
    end

    def dead_size
      Cogworker.config.redis { |c| c.zcard(RedisKeys::DEAD) }
    end

    # The raw `INFO` reply as a flat Hash (server/clients/memory/stats/...
    # sections all merged together, same as the `redis` gem always returns
    # it) — the Web UI's Stats tab picks a handful of fields (version,
    # uptime, connected clients, memory usage) back out of this itself,
    # rather than this class pre-selecting/renaming them, so a future
    # consumer isn't limited to whatever subset this method chose.
    def redis_info
      Cogworker.config.redis(&:info)
    end

    private

    def queue_names
      Cogworker.config.redis { |c| c.smembers(RedisKeys::QUEUES) }
    end
  end
end
