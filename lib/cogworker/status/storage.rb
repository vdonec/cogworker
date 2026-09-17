# frozen_string_literal: true

module Cogworker
  module Status
    # Shared read/write for `status:<jid>` — a Hash with `status`,
    # `update_time`, `class`, `queue`, and optional `error_class`/
    # `error_message`/`pct`/`message`. TTL is refreshed on every write so a
    # long-running job's status doesn't expire mid-flight relative to its
    # own last update.
    module Storage
      module_function

      def write(jid, expiration, fields)
        cleaned = fields.compact.transform_values(&:to_s)
        return if cleaned.empty?

        key = "status:#{jid}"
        Cogworker.config.redis do |c|
          c.hset(key, *cleaned.to_a.flatten)
          c.expire(key, expiration.to_i)
        end
      end

      def read(jid)
        hash = Cogworker.config.redis { |c| c.hgetall("status:#{jid}") }
        hash.empty? ? nil : hash
      end
    end
  end
end
