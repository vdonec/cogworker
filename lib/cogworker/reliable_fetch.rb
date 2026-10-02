# frozen_string_literal: true

require 'digest/sha1'
require 'json'

module Cogworker
  # The default fetch (`config.fetch = :reliable`): every job is moved
  # atomically (`LMOVE`, Redis >= 6.2) from its queue onto this process's own
  # `cogworker:inprogress:<identity>` list, and only removed from there
  # (`acknowledge`) once it has finished — succeeded, or been routed to
  # retry/dead. A job is therefore never only in a processor's memory: if the
  # process dies mid-job (OOM, SIGKILL, a host going away), the job is still
  # on that list, and `recover_orphans` (run by every live process's
  # `Scheduled` poller) puts it back on its queue once the dead process has
  # gone `config.orphan_threshold` (default 5 min) without a heartbeat. The trade-off is at-least-once delivery: a job
  # that was partly done when its process died runs again from the start.
  #
  # `LMOVE` can only take from one list at a time, so there's no blocking
  # wait across several weighted queues the way `BasicFetch`'s single
  # `BRPOP` has: instead, one round trip (FETCH_SCRIPT) tries the queues in
  # weighted-shuffled order and takes the first job it finds, and an empty
  # round sleeps EMPTY_POLL_INTERVAL before the next. Weighting and
  # `Queue#pause!` behave exactly as in BasicFetch.
  class ReliableFetch < BasicFetch
    # The first pause after an empty round; each further empty round in a
    # row doubles it, up to `config.fetch_idle_max_interval` (default 1s),
    # and finding a job resets it. That cap is the worst-case pickup delay
    # on an idle process — the trade-off against how often idle processors
    # poll Redis (at 0.25s flat, 4 calls/s per thread).
    EMPTY_POLL_INTERVAL = 0.25
    MIN_REDIS_VERSION = Gem::Version.new('6.2')

    # KEYS[1..n-1] = queue keys, in the order to try; KEYS[n] = in-progress list.
    FETCH_SCRIPT = <<~LUA
      local dest = KEYS[#KEYS]
      for i = 1, #KEYS - 1 do
        local job = redis.call("LMOVE", KEYS[i], dest, "RIGHT", "LEFT")
        if job then
          return {KEYS[i], job}
        end
      end
      return false
    LUA

    # (Run by hash, like every script here — see LuaScript.)
    FETCH_SCRIPT_SHA = LuaScript.sha(FETCH_SCRIPT)

    # Lua shared by every script here that puts a job back on its queue:
    # onto the end its queue is popped from (so it runs next), onto
    # `default_queue` if its own `queue` can't be read (the Processor then
    # buries it as unparseable) — and a job from an `until_executed`
    # periodic entry re-takes its running lock on the way
    # (Periodic::RunningLock::RETAKE_FUNCTION), so the ticker can't start
    # the next slot alongside the requeued run.
    REQUEUE_JOB_FUNCTION = Periodic::RunningLock::RETAKE_FUNCTION + <<~LUA
      local function requeue_job(job, queue_prefix, default_queue, lock_prefix, lock_ttl)
        local queue = default_queue
        local ok, decoded = pcall(cjson.decode, job)
        if ok and type(decoded) == "table" then
          if type(decoded["queue"]) == "string" and decoded["queue"] ~= "" then
            queue = decoded["queue"]
          end
          local pjid, jid = decoded["periodic_pjid"], decoded["jid"]
          if decoded["periodic_until_executed"] == true and type(pjid) == "string" and type(jid) == "string" then
            retake_running_lock(lock_prefix .. pjid, jid, lock_ttl)
          end
        end
        redis.call("RPUSH", queue_prefix .. queue, job)
      end
    LUA

    # KEYS[1] = an in-progress list, KEYS[2] = its owner's presence key,
    # KEYS[3] = LAST_BEAT; ARGV[1..4] = requeue_job's prefix/default
    # queue/lock prefix/lock TTL, ARGV[5] = owner identity, ARGV[6] = orphan
    # threshold, or "" to requeue unconditionally (this process's own list,
    # on shutdown). Returns how many it moved, or -1 if the owner turned
    # out to be alive. Oldest first, so recovered jobs keep their order. The
    # "is the owner really dead?" check (see ReliableFetch.dead?) is made
    # here, atomically with the requeue: checked separately, an owner that
    # beat in between would lose jobs it is still running to a second run.
    # Atomic per call, so two processes recovering one list can't both move
    # a job.
    REQUEUE_SCRIPT = REQUEUE_JOB_FUNCTION + <<~LUA
      if ARGV[6] ~= "" then
        if redis.call("EXISTS", KEYS[2]) == 1 then
          return -1
        end
        local last = redis.call("HGET", KEYS[3], ARGV[5])
        if last then
          if redis.replicate_commands then redis.replicate_commands() end
          local now = tonumber(redis.call("TIME")[1])
          if now - tonumber(last) <= tonumber(ARGV[6]) then
            return -1
          end
        end
      end
      local moved = 0
      while true do
        local job = redis.call("LPOP", KEYS[1])
        if not job then
          return moved
        end
        requeue_job(job, ARGV[1], ARGV[2], ARGV[3], ARGV[4])
        moved = moved + 1
      end
    LUA

    # KEYS[1] = an in-progress list; ARGV[1] = one job on it, ARGV[2..5] =
    # requeue_job's arguments. That one job, if still on the list, back on
    # its queue: `give_back`, and `reconcile`'s strays.
    REQUEUE_ONE_SCRIPT = REQUEUE_JOB_FUNCTION + <<~LUA
      if redis.call("LREM", KEYS[1], 1, ARGV[1]) == 1 then
        requeue_job(ARGV[1], ARGV[2], ARGV[3], ARGV[4], ARGV[5])
        return 1
      end
      return 0
    LUA

    # KEYS[1] = in-progress list, KEYS[2] = retry/dead ZSET; ARGV[1] = the
    # job as fetched, ARGV[2] = score, ARGV[3] = payload to file. Off the
    # in-progress list and into the ZSET in one step; a no-op if it's no
    # longer in progress (already requeued by a shutdown).
    INTERRUPT_SCRIPT = <<~LUA
      if redis.call("LREM", KEYS[1], 1, ARGV[1]) == 1 then
        redis.call("ZADD", KEYS[2], ARGV[2], ARGV[3])
        return 1
      end
      return 0
    LUA

    class << self
      # A connection error propagates: can't tell yet, so the caller
      # (Manager#fetch_class) resolves again on its next use, instead of
      # memoizing a guess made while Redis was unreachable. Anything else
      # (INFO restricted, an odd version string) assumes a current server —
      # the runtime fall-back (UnsupportedError) still catches a wrong guess.
      def supported?
        version = Cogworker.config.redis { |c| c.info('server')['redis_version'] }
        Gem::Version.new(version) >= MIN_REDIS_VERSION
      rescue Redis::BaseConnectionError
        raise
      rescue StandardError
        true
      end

      # Puts every job still on `identity`'s in-progress list back on its
      # queue; returns how many — or -1 if `if_dead_for:` is given and the
      # owner turns out not to be dead (see REQUEUE_SCRIPT). Used without
      # it for this process's own unfinished jobs on shutdown
      # (`Manager#stop!`), with it for presumed-dead processes' lists.
      def requeue_in_progress(identity, if_dead_for: nil)
        Cogworker.config.redis do |c|
          LuaScript.run(c, REQUEUE_SCRIPT,
                 keys: [RedisKeys.in_progress(identity), RedisKeys.process(identity), RedisKeys::LAST_BEAT],
                 argv: [*requeue_args, identity, if_dead_for.to_s])
        end
      end

      def requeue_args
        [RedisKeys::QUEUE_PREFIX, 'default', RedisKeys.periodic_running(''), Periodic::RunningLock.queued_ttl]
      end

      # Requeues the in-progress list of every process that has died without
      # a clean shutdown. "Dead" means its presence key is gone (no beat for
      # Heartbeat::TTL) *and* `config.orphan_threshold` has passed since its
      # last recorded beat (LAST_BEAT, on Redis's clock) — the presence key
      # alone expires after a minute, too eagerly for a live process that
      # merely couldn't beat for a while (a Redis outage or failover, a long
      # GVL-holding call), whose running jobs would then run twice. With no
      # recorded beat at all (lists from before LAST_BEAT existed), the
      # presence key alone decides. Checked inside REQUEUE_SCRIPT, atomically
      # with the requeue. A process always beats before its first fetch
      # (`Heartbeat#start!`). Walks IN_PROGRESS_IDENTITIES (each
      # reliable-fetch process registers itself there on every beat) rather
      # than SCANning the keyspace; `scan: true` (once per reliable process,
      # at boot) also picks up lists from before that set existed.
      def recover_orphans(scan: false)
        own = Cogworker.identity
        candidate_identities(scan: scan).sum do |identity|
          next 0 if identity == own

          moved = requeue_in_progress(identity, if_dead_for: Cogworker.config.orphan_threshold)
          next 0 if moved.negative? # alive after all: keep its registration and last beat

          forget_if_empty(identity)
          Cogworker.logger.warn { "requeued #{moved} job(s) left in progress by dead process #{identity}" } if moved.positive?
          moved
        end
      end

      # This process's own in-progress entries that no processor thread is
      # running (not in `cogworker:workers:<identity>`) — left behind when
      # neither acknowledging nor handing a job back worked. Requeued once
      # they've been seen stray on two calls in a row (the caller passes
      # back what the previous call returned), which rules out a job caught
      # in the instant between being fetched and registered. Returns this
      # call's strays that weren't requeued yet.
      def reconcile(identity, previous_strays = [])
        Cogworker.config.redis do |c|
          listed = c.lrange(RedisKeys.in_progress(identity), 0, -1)
          running = c.hvals(RedisKeys.workers(identity)).filter_map { |raw| parse_hash(raw)&.dig('payload', 'jid') }
          strays = listed.reject { |raw| running.include?(parse_hash(raw)&.fetch('jid', nil)) }
          (strays & previous_strays).each do |raw|
            next unless LuaScript.run(c, REQUEUE_ONE_SCRIPT, keys: [RedisKeys.in_progress(identity)],
                                                            argv: [raw, *requeue_args]) == 1

            Cogworker.logger.warn { "requeued stray in-progress job jid=#{parse_hash(raw)&.fetch('jid', nil)}" }
          end
          strays - previous_strays
        end
      end

      def parse_hash(raw)
        value = JSON.parse(raw)
        value.is_a?(Hash) ? value : nil
      rescue JSON::ParserError
        nil
      end

      def candidate_identities(scan:)
        Cogworker.config.redis do |c|
          identities = c.smembers(RedisKeys::IN_PROGRESS_IDENTITIES)
          next identities unless scan

          scanned = c.scan_each(match: "#{RedisKeys::IN_PROGRESS_PREFIX}*").map do |key|
            key.delete_prefix(RedisKeys::IN_PROGRESS_PREFIX)
          end
          identities | scanned
        end
      end

      def forget_if_empty(identity)
        Cogworker.config.redis do |c|
          next unless c.llen(RedisKeys.in_progress(identity)).zero?

          c.srem?(RedisKeys::IN_PROGRESS_IDENTITIES, identity)
          c.hdel(RedisKeys::LAST_BEAT, identity)
        end
      end
    end

    def retrieve_work
      keys = active_keys
      if keys.empty?
        interruptible_sleep(TIMEOUT)
        return nil
      end

      distinct = keys.uniq
      return blocking_fetch(distinct.first) if distinct.size == 1

      result = run_fetch_script(keys.shuffle.uniq + [RedisKeys.in_progress(Cogworker.identity)])
      unless result
        idle_sleep
        return nil
      end

      @idle_interval = nil
      queue_key, raw_job = result
      UnitOfWork.new(queue_key.delete_prefix(RedisKeys::QUEUE_PREFIX), raw_job)
    end

    # Atomically moves a fetched-but-unstarted job off the in-progress list
    # and back to the end of its queue that's popped next. A no-op if it's
    # no longer in progress (already requeued by `requeue_in_progress`).
    def give_back(work)
      Cogworker.config.redis do |c|
        LuaScript.run(c, REQUEUE_ONE_SCRIPT, keys: [RedisKeys.in_progress(Cogworker.identity)],
                                            argv: [work.raw_job, *self.class.requeue_args])
      end
    end

    def interrupt(work, set, score, payload)
      Cogworker.config.redis do |c|
        LuaScript.run(c, INTERRUPT_SCRIPT, keys: [RedisKeys.in_progress(Cogworker.identity), set],
                                          argv: [work.raw_job, score, payload])
      end
    end

    def acknowledge(work)
      Cogworker.config.redis { |c| c.lrem(RedisKeys.in_progress(Cogworker.identity), 1, work.raw_job) }
    end

    private

    # With a single (unpaused) queue there's no weighting to honor, so no
    # need to poll: a blocking BLMOVE waits on the server and returns the
    # moment a job arrives, for up to TIMEOUT — same as BasicFetch's BRPOP.
    def blocking_fetch(queue_key)
      raw_job = Cogworker.config.redis do |c|
        c.blmove(queue_key, RedisKeys.in_progress(Cogworker.identity), 'RIGHT', 'LEFT', timeout: TIMEOUT)
      end
      raw_job && UnitOfWork.new(queue_key.delete_prefix(RedisKeys::QUEUE_PREFIX), raw_job)
    rescue Redis::CommandError => e
      raise unless e.message.match?(/unknown (redis )?command/i)

      raise UnsupportedError, e.message
    end

    def run_fetch_script(keys)
      Cogworker.config.redis { |c| LuaScript.run(c, FETCH_SCRIPT, keys: keys) }
    rescue Redis::CommandError => e
      raise unless e.message.match?(/unknown (redis )?command/i)

      raise UnsupportedError, e.message
    end

    # Jittered (75–100% of the interval) so a process's threads, all idle
    # at once, don't keep polling in lockstep.
    def idle_sleep
      max = Cogworker.config.fetch_idle_max_interval
      @idle_interval = @idle_interval ? [@idle_interval * 2, max].min : [EMPTY_POLL_INTERVAL, max].min
      interruptible_sleep(@idle_interval * (0.75 + (rand * 0.25)))
    end
  end
end
