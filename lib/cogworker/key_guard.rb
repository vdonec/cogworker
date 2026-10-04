# frozen_string_literal: true

require 'securerandom'

module Cogworker
  # Finds this gem's Redis keys holding the wrong type of value — which
  # only a manual write or data corruption produces, but which then breaks
  # every command on that key, deterministically: a queue that can't be
  # pushed to, a `dead` set nothing can be filed in, a registry that fails
  # every beat — and moves each such key out of the way, to
  # `cogworker:quarantine:<key>:<time>:<random>` (kept QUARANTINE_TTL for a human to
  # look at), with an error in the log. Everything then carries on with a
  # fresh, empty key of the right type. Run by every process's Scheduled
  # poller at boot and every CHECK_INTERVAL.
  module KeyGuard
    CHECK_INTERVAL = 60
    QUARANTINE_TTL = 30 * 24 * 60 * 60
    QUARANTINE_PREFIX = 'cogworker:quarantine:'

    FIXED = {
      RedisKeys::SCHEDULE => 'zset', RedisKeys::RETRY => 'zset', RedisKeys::DEAD => 'zset',
      RedisKeys::QUEUES => 'set', RedisKeys::PROCESSES => 'set', RedisKeys::PAUSED_QUEUES => 'set',
      RedisKeys::IN_PROGRESS_IDENTITIES => 'set', RedisKeys::LAST_BEAT => 'hash',
      RedisKeys::REPEAT_ORPHANS => 'list', RedisKeys::UNSETTLED => 'list', RedisKeys::PERIODIC_SCHEDULE => 'hash',
      RedisKeys::LIVE_QUEUES => 'zset',
      RedisKeys::PERIODIC_DISABLED => 'set', RedisKeys::STATS_PROCESSED => 'string',
      RedisKeys::STATS_FAILED => 'string'
    }.freeze

    # KEYS[1] = the key, KEYS[2] = its quarantine name; ARGV[1] = expected
    # type, ARGV[2] = quarantine TTL. Re-checked here, atomically with the
    # move, so a key fixed (or recreated) in between is left alone.
    QUARANTINE_SCRIPT = <<~LUA
      local actual = redis.call("TYPE", KEYS[1])["ok"]
      if actual == "none" or actual == ARGV[1] then
        return 0
      end
      redis.call("RENAME", KEYS[1], KEYS[2])
      redis.call("EXPIRE", KEYS[2], ARGV[2])
      return 1
    LUA

    module_function

    # Returns the keys quarantined.
    def check(queues: Cogworker.config.queues)
      expected = expected_types(queues)
      actual = Cogworker.config.redis do |c|
        c.pipelined { |p| expected.each_key { |key| p.type(key) } }
      end
      expected.keys.zip(actual).filter_map do |key, type|
        next if type == 'none' || type == expected[key]

        key if quarantine(key, expected[key], type)
      end
    end

    # The fixed keys, plus the per-queue and per-process ones currently
    # listed in them (only where the listing itself is readable).
    def expected_types(queues)
      types = FIXED.dup
      queue_names = Array(queues) | readable_members(RedisKeys::QUEUES)
      queue_names.each { |q| types[RedisKeys.queue(q)] = 'list' }
      readable_members(RedisKeys::IN_PROGRESS_IDENTITIES).each { |id| types[RedisKeys.in_progress(id)] = 'list' }
      readable_members(RedisKeys::PROCESSES).each do |id|
        types[RedisKeys.process(id)] = 'hash'
        types[RedisKeys.workers(id)] = 'hash'
      end
      readable_fields(RedisKeys::PERIODIC_SCHEDULE).each do |pjid|
        types[RedisKeys.periodic_running(pjid)] = 'string'
        types[RedisKeys.periodic_last_slot(pjid)] = 'string'
      end
      types
    end

    def readable_fields(hash)
      Cogworker.config.redis { |c| c.hkeys(hash) }
    rescue Redis::CommandError
      []
    end

    MAX_COPIES = 5

    # Keeps the newest MAX_COPIES quarantined copies of one key: something
    # that keeps writing the wrong type would otherwise leave one more every
    # CHECK_INTERVAL, for QUARANTINE_TTL. (A SCAN, but only on the rare
    # occasion a key actually gets quarantined.)
    def prune_copies(key)
      prefix = "#{QUARANTINE_PREFIX}#{key}:"
      exact = /\A#{Regexp.escape(prefix)}(\d+):\h{8}\z/ # this key's copies only — not `<key>:<more>:...`'s
      Cogworker.config.redis do |c|
        copies = c.scan_each(match: "#{glob_escape(prefix)}*").select { |name| name.match?(exact) }
        stale = copies.sort_by { |name| name[exact, 1].to_i }.reverse.drop(MAX_COPIES)
        c.del(*stale) unless stale.empty?
      end
    rescue StandardError => e
      Cogworker.logger.error { "pruning quarantined copies of #{key} failed: #{e.class}: #{e.message}" }
    end

    def glob_escape(text)
      text.gsub(/[*?\[\]\\]/) { |ch| "\\#{ch}" }
    end

    def readable_members(set)
      Cogworker.config.redis { |c| c.smembers(set) }
    rescue Redis::CommandError
      [] # itself of the wrong type: quarantined this round, listed again next
    end

    def quarantine(key, expected, actual)
      # Unique per move: a second quarantine of the same key within the same
      # second must not overwrite (RENAME) the first one's copy.
      # Milliseconds, so copies made within one second still sort by age.
      target = "#{QUARANTINE_PREFIX}#{key}:#{(Time.now.to_f * 1000).to_i}:#{SecureRandom.hex(4)}"
      moved = Cogworker.config.redis do |c|
        LuaScript.run(c, QUARANTINE_SCRIPT, keys: [key, target], argv: [expected, QUARANTINE_TTL])
      end
      return false unless moved == 1

      prune_copies(key)
      Cogworker.logger.error do
        "#{key} held a #{actual}, not a #{expected}: moved to #{target} (kept #{QUARANTINE_TTL / 86_400} days)"
      end
      true
    end
  end
end
