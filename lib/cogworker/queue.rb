# frozen_string_literal: true

require 'json'

module Cogworker
  # One named queue: size/latency plus enumeration of its JobRecords, oldest
  # (soon-to-be-popped) entries last, newest first.
  class Queue
    include Enumerable

    def initialize(name = 'default')
      @name = name
      @key = RedisKeys.queue(name)
    end

    attr_reader :name

    def size
      Cogworker.config.redis { |c| c.llen(@key) }
    end

    # FIFO: LPUSH on push, so index 0 is the newest and -1 the oldest
    # (next to be popped) — latency is measured off that tail entry.
    def latency
      oldest = Cogworker.config.redis { |c| c.lindex(@key, -1) }
      return 0 unless oldest

      job = JSON.parse(oldest)
      enqueued_at = job['enqueued_at'] || job['created_at']
      return 0 unless enqueued_at

      [Time.now.to_f - enqueued_at, 0].max
    end

    # Removes every occurrence of this exact raw job entry (matched by full
    # JSON string, same "raw" identity `Routes::Dead`/`Routes::Retries`
    # already key their own delete/retry actions off).
    def delete(raw)
      Cogworker.config.redis { |c| c.lrem(@key, 0, raw) }
    end

    def clear
      Cogworker.config.redis { |c| c.del(@key) }
    end

    def each
      page = 0
      per = 50
      loop do
        entries = Cogworker.config.redis { |c| c.lrange(@key, page * per, (page * per) + per - 1) }
        break if entries.empty?

        entries.each { |raw| yield JobRecord.new(raw) }
        break if entries.size < per

        page += 1
      end
    end
  end
end
