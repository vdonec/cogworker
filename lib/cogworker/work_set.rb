# frozen_string_literal: true

require 'json'

module Cogworker
  class WorkSet
    include Enumerable

    def each
      ProcessSet.new.each do |process|
        identity = process['identity']
        workers = Cogworker.config.redis { |c| c.hgetall(RedisKeys.workers(identity)) }
        workers.each do |tid, raw|
          yield identity, tid, Work.new(identity, tid, JSON.parse(raw))
        end
      end
    end

    def size
      count { true }
    end
  end
end
