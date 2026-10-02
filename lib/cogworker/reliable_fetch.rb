# frozen_string_literal: true

require 'digest/sha1'

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

    # The hot path runs this by hash (EVALSHA), not by shipping the whole
    # script text on every poll; see #run_fetch_script.
    FETCH_SCRIPT_SHA = Digest::SHA1.hexdigest(FETCH_SCRIPT)

    # KEYS[1] = an in-progress list; ARGV[1] = queue key prefix; ARGV[2] =
    # queue for a payload whose own `queue` can't be read (the Processor
    # then buries it as unparseable); ARGV[3] = periodic running-lock key
    # prefix, ARGV[4] = its queued TTL. Oldest first, each onto the end its
    # queue is popped from, so recovered jobs run next, in their original
    # order. Atomic per call: two processes recovering the same list can't
    # both move one job. A job from an `until_executed` periodic entry
    # re-takes its running lock on the way (same rule as
    # Periodic::RunningLock::RETAKE_FUNCTION), so the ticker can't start
    # the next slot alongside the recovered run.
    REQUEUE_SCRIPT = Periodic::RunningLock::RETAKE_FUNCTION + <<~LUA
      local moved = 0
      while true do
        local job = redis.call("LPOP", KEYS[1])
        if not job then
          return moved
        end
        local queue = ARGV[2]
        local ok, decoded = pcall(cjson.decode, job)
        if ok and type(decoded) == "table" then
          if type(decoded["queue"]) == "string" then
            queue = decoded["queue"]
          end
          local pjid, jid = decoded["periodic_pjid"], decoded["jid"]
          if decoded["periodic_until_executed"] == true and type(pjid) == "string" and type(jid) == "string" then
            retake_running_lock(ARGV[3] .. pjid, jid, ARGV[4])
          end
        end
        redis.call("RPUSH", ARGV[1] .. queue, job)
        moved = moved + 1
      end
    LUA

    # KEYS[1] = in-progress list, KEYS[2] = the job's queue; ARGV[1] = job.
    GIVE_BACK_SCRIPT = <<~LUA
      if redis.call("LREM", KEYS[1], 1, ARGV[1]) == 1 then
        redis.call("RPUSH", KEYS[2], ARGV[1])
      end
    LUA

    class << self
      def supported?
        version = Cogworker.config.redis { |c| c.info('server')['redis_version'] }
        Gem::Version.new(version) >= MIN_REDIS_VERSION
      rescue StandardError
        true # can't tell (Redis not reachable yet): assume a current server
      end

      # Puts every job still on `identity`'s in-progress list back on its
      # queue; returns how many. Used for this process's own unfinished jobs
      # on shutdown (`Manager#stop!`) and for dead processes' lists.
      def requeue_in_progress(identity)
        Cogworker.config.redis do |c|
          c.eval(REQUEUE_SCRIPT, keys: [RedisKeys.in_progress(identity)],
                                 argv: [RedisKeys::QUEUE_PREFIX, 'default', RedisKeys.periodic_running(''),
                                        Periodic::RunningLock.queued_ttl])
        end
      end

      # Requeues the in-progress list of every process that has gone
      # `config.orphan_threshold` without a heartbeat — i.e. that died
      # without a clean shutdown (see #dead?). A process always
      # writes its heartbeat before its first fetch (`Heartbeat#start!`), so
      # a live process's list is never mistaken for an orphan. Walks
      # IN_PROGRESS_IDENTITIES (each reliable-fetch process registers itself
      # there on every beat) rather than SCANning the keyspace; `scan: true`
      # (once per process, at boot) also picks up lists from before that
      # set existed.
      def recover_orphans(scan: false)
        own = Cogworker.identity
        candidate_identities(scan: scan).sum do |identity|
          next 0 if identity == own || !dead?(identity)

          requeue_in_progress(identity).tap do |moved|
            forget_if_empty(identity)
            next unless moved.positive?

            Cogworker.logger.warn { "requeued #{moved} job(s) left in progress by dead process #{identity}" }
          end
        end
      end

      # Its presence key gone (no beat for Heartbeat::TTL) is not enough on
      # its own: a live process that just couldn't beat for a minute (a
      # Redis outage or failover, a long GVL-holding call) would lose its
      # in-progress jobs to a second, parallel run. It also has to have gone
      # `orphan_threshold` since its last recorded beat — compared on
      # Redis's clock on both sides, so host clock skew doesn't matter. No
      # recorded beat at all (a list from before LAST_BEAT existed) falls
      # back to the presence key alone.
      def dead?(identity)
        Cogworker.config.redis do |c|
          next false if c.exists?(RedisKeys.process(identity))

          last = c.hget(RedisKeys::LAST_BEAT, identity)
          last.nil? || c.time.first - last.to_f > Cogworker.config.orphan_threshold
        end
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
        sleep(TIMEOUT)
        return nil
      end

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
        c.eval(GIVE_BACK_SCRIPT, keys: [RedisKeys.in_progress(Cogworker.identity), RedisKeys.queue(work.queue)],
                                 argv: [work.raw_job])
      end
    end

    def acknowledge(work)
      Cogworker.config.redis { |c| c.lrem(RedisKeys.in_progress(Cogworker.identity), 1, work.raw_job) }
    end

    private

    def run_fetch_script(keys)
      Cogworker.config.redis do |c|
        c.evalsha(FETCH_SCRIPT_SHA, keys: keys)
      rescue Redis::CommandError => e
        raise unless e.message.start_with?('NOSCRIPT')

        c.eval(FETCH_SCRIPT, keys: keys) # loads it into the script cache for next time
      end
    rescue Redis::CommandError => e
      raise unless e.message.match?(/unknown (redis )?command/i)

      raise UnsupportedError, e.message
    end

    # Jittered (75–100% of the interval) so a process's threads, all idle
    # at once, don't keep polling in lockstep.
    def idle_sleep
      max = Cogworker.config.fetch_idle_max_interval
      @idle_interval = @idle_interval ? [@idle_interval * 2, max].min : [EMPTY_POLL_INTERVAL, max].min
      sleep(@idle_interval * (0.75 + (rand * 0.25)))
    end
  end
end
