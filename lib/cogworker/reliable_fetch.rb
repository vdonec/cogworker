# frozen_string_literal: true

module Cogworker
  # The default fetch (`config.fetch = :reliable`): every job is moved
  # atomically (`LMOVE`, Redis >= 6.2) from its queue onto this process's own
  # `cogworker:inprogress:<identity>` list, and only removed from there
  # (`acknowledge`) once it has finished — succeeded, or been routed to
  # retry/dead. A job is therefore never only in a processor's memory: if the
  # process dies mid-job (OOM, SIGKILL, a host going away), the job is still
  # on that list, and `recover_orphans` (run by every live process's
  # `Scheduled` poller) puts it back on its queue once the dead process's
  # heartbeat has expired. The trade-off is at-least-once delivery: a job
  # that was partly done when its process died runs again from the start.
  #
  # `LMOVE` can only take from one list at a time, so there's no blocking
  # wait across several weighted queues the way `BasicFetch`'s single
  # `BRPOP` has: instead, one round trip (FETCH_SCRIPT) tries the queues in
  # weighted-shuffled order and takes the first job it finds, and an empty
  # round sleeps EMPTY_POLL_INTERVAL before the next. Weighting and
  # `Queue#pause!` behave exactly as in BasicFetch.
  class ReliableFetch < BasicFetch
    EMPTY_POLL_INTERVAL = 0.25 # seconds; worst-case pickup delay on an idle process
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

    # KEYS[1] = an in-progress list; ARGV[1] = queue key prefix; ARGV[2] =
    # queue for a payload whose own `queue` can't be read (the Processor
    # then buries it as unparseable). Oldest first, each onto the end its
    # queue is popped from, so recovered jobs run next, in their original
    # order. Atomic per call: two processes recovering the same list can't
    # both move one job.
    REQUEUE_SCRIPT = <<~LUA
      local moved = 0
      while true do
        local job = redis.call("LPOP", KEYS[1])
        if not job then
          return moved
        end
        local queue = ARGV[2]
        local ok, decoded = pcall(cjson.decode, job)
        if ok and type(decoded) == "table" and type(decoded["queue"]) == "string" then
          queue = decoded["queue"]
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
          c.eval(REQUEUE_SCRIPT, keys: [RedisKeys.in_progress(identity)], argv: [RedisKeys::QUEUE_PREFIX, 'default'])
        end
      end

      # Requeues the in-progress list of every process whose heartbeat key
      # is gone — i.e. that died without a clean shutdown. A process always
      # writes its heartbeat before its first fetch (`Heartbeat#start!`), so
      # a live process's list is never mistaken for an orphan.
      def recover_orphans
        own = Cogworker.identity
        keys = Cogworker.config.redis { |c| c.scan_each(match: "#{RedisKeys::IN_PROGRESS_PREFIX}*").to_a }
        keys.sum do |key|
          identity = key.delete_prefix(RedisKeys::IN_PROGRESS_PREFIX)
          next 0 if identity == own || Cogworker.config.redis { |c| c.exists?(RedisKeys.process(identity)) }

          requeue_in_progress(identity).tap do |moved|
            next unless moved.positive?

            Cogworker.logger.warn { "requeued #{moved} job(s) left in progress by dead process #{identity}" }
          end
        end
      end
    end

    def retrieve_work
      keys = active_keys
      if keys.empty?
        sleep(TIMEOUT)
        return nil
      end

      result = Cogworker.config.redis do |c|
        c.eval(FETCH_SCRIPT, keys: keys.shuffle.uniq + [RedisKeys.in_progress(Cogworker.identity)])
      end
      unless result
        sleep(EMPTY_POLL_INTERVAL)
        return nil
      end

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
  end
end
