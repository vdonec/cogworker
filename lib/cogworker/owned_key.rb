# frozen_string_literal: true

module Cogworker
  # Compare-and-act on a lock key whose value is its owner's jid
  # (`periodic:running:<pjid>`, `cogworker:unique:<digest>`): the EXPIRE/DEL
  # only happens if the key still holds that exact jid, atomically — so a
  # stray older run can never shorten, extend or release a lock that has
  # since passed to a newer one.
  module OwnedKey
    EXPIRE_IF_OWNED = <<~LUA
      if redis.call("GET", KEYS[1]) == ARGV[1] then
        return redis.call("EXPIRE", KEYS[1], ARGV[2])
      end
      return 0
    LUA

    DELETE_IF_OWNED = <<~LUA
      if redis.call("GET", KEYS[1]) == ARGV[1] then
        return redis.call("DEL", KEYS[1])
      end
      return 0
    LUA

    module_function

    def expire(key, owner, ttl, conn = nil)
      run(conn, EXPIRE_IF_OWNED, key, [owner, ttl.ceil])
    end

    def delete(key, owner, conn = nil)
      run(conn, DELETE_IF_OWNED, key, [owner])
    end

    def run(conn, script, key, argv)
      return conn.eval(script, keys: [key], argv: argv) if conn

      Cogworker.config.redis { |c| c.eval(script, keys: [key], argv: argv) }
    end
  end
end
