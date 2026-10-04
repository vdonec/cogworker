# frozen_string_literal: true

require 'json'

module Cogworker
  # Every live worker process, as published by its Heartbeat — one
  # Cogworker::Process per `cogworker:processes` member whose presence key
  # still exists (stale members are pruned while iterating).
  class ProcessSet
    include Enumerable

    def each
      identities = Cogworker.config.redis { |c| c.smembers(RedisKeys::PROCESSES) }
      identities.each do |identity|
        info = Cogworker.config.redis { |c| c.hgetall(RedisKeys.process(identity)) }
        if info.empty?
          Cogworker.config.redis { |c| c.srem?(RedisKeys::PROCESSES, identity) }
          next
        end

        parsed = JSON.parse(info['info'] || '{}').merge(
          'identity' => identity, 'busy' => info['busy'].to_i, 'quiet' => info['quiet'] == 'true'
        )
        yield Process.new(parsed)
      end
    end

    def size
      count { true }
    end
  end
end
