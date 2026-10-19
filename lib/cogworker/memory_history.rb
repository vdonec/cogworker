# frozen_string_literal: true

module Cogworker
  # Per-process RSS for the last 24 hours, in SLOTS fixed SAMPLE_SECONDS
  # slots, feeding the memory sparkline on the Workers tab's process cards.
  # Written by Heartbeat on every beat; a slot keeps the *highest* reading
  # any beat in it took (a peak is what matters for memory, and a short
  # spike between two slot boundaries would otherwise vanish). One ZSET per
  # identity, scored by slot start, members "<slot_start>:<rss_kb>" — so a
  # slot's sample is unique by score, not by value. Old slots are trimmed
  # on every write, and the key itself expires a little after the window,
  # so a process that's gone leaves nothing behind for long.
  module MemoryHistory
    SAMPLE_SECONDS = 900
    SLOTS = 96 # 24h of 15-minute slots
    WINDOW = SLOTS * SAMPLE_SECONDS
    KEY_TTL = WINDOW + 3600

    # KEYS[1] = the identity's ZSET; ARGV = slot start, rss_kb, window, TTL.
    RECORD_SCRIPT = <<~LUA
      local slot = tonumber(ARGV[1])
      local kb = tonumber(ARGV[2])
      for _, member in ipairs(redis.call("ZRANGEBYSCORE", KEYS[1], slot, slot)) do
        local seen = tonumber(string.match(member, ":(%d+)$"))
        if seen and seen >= kb then kb = nil break end
      end
      if kb then
        redis.call("ZREMRANGEBYSCORE", KEYS[1], slot, slot)
        redis.call("ZADD", KEYS[1], slot, slot .. ":" .. kb)
      end
      redis.call("ZREMRANGEBYSCORE", KEYS[1], "-inf", "(" .. (slot - tonumber(ARGV[3])))
      redis.call("EXPIRE", KEYS[1], ARGV[4])
      return 1
    LUA

    module_function

    def record(conn, identity, rss_kb, at: Time.now.to_i)
      return unless rss_kb

      LuaScript.run(conn, RECORD_SCRIPT, keys: [RedisKeys.memory_history(identity)],
                                         argv: [slot_for(at), rss_kb.to_i, WINDOW, KEY_TTL])
    end

    # Per identity, exactly SLOTS `[slot_start, rss_kb_or_nil]` pairs,
    # oldest first, the last one being the current (still filling) slot —
    # a slot no beat wrote to is `nil`, so the chart always spans the full
    # 24h whatever data exists. One pipelined read for every identity.
    def series(identities, now: Time.now.to_i)
      return {} if identities.empty?

      first = slot_for(now) - ((SLOTS - 1) * SAMPLE_SECONDS)
      raw = Cogworker.config.redis do |c|
        c.pipelined do |pipe|
          identities.each { |id| pipe.zrangebyscore(RedisKeys.memory_history(id), first, '+inf') }
        end
      end
      identities.zip(raw).to_h do |id, members|
        values = Array(members).to_h { |m| m.split(':', 2).map(&:to_i) }
        [id, Array.new(SLOTS) { |i| [first + (i * SAMPLE_SECONDS), values[first + (i * SAMPLE_SECONDS)]] }]
      end
    end

    def slot_for(time)
      time.to_i - (time.to_i % SAMPLE_SECONDS)
    end
  end
end
