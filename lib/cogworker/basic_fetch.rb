# frozen_string_literal: true

require 'json'

module Cogworker
  # `config.fetch = :basic`: pops jobs off Redis lists with one blocking
  # `BRPOP`. Once popped, a job exists only in the processor's memory (and
  # its `cogworker:workers:<identity>` entry, which expires with the
  # process), so a process that dies mid-job loses it — see ReliableFetch,
  # the default, for the alternative.
  #
  # Queue names repeated in the process's queue list represent weight;
  # since BRPOP itself scans its key list
  # strictly left-to-right, weighting is implemented by shuffling the
  # (already-expanded, so repeats survive) key list before every fetch cycle
  # — the more often a name appears, the more likely it lands first.
  class BasicFetch
    TIMEOUT = 2 # seconds; also how often a stopped/quieted processor notices and exits its fetch loop.

    # `stopping:` lets a fetcher cut its own waits short once shutdown has
    # begun (Processor passes the Manager's `stopping?`), so a long idle
    # pause can't hold up `Manager#stop!`.
    def initialize(queues, stopping: -> { false })
      @queue_keys = Array(queues).map { |q| RedisKeys.queue(q) }
      @stopping = stopping
    end

    # Re-reads `cogworker:paused_queues` on every single fetch (not once at
    # `initialize`, and not cached) — a `Queue#pause!`/`#resume!` from the
    # Web UI takes effect on this processor's very next cycle, not just for
    # ones started after the toggle. If every one of this processor's
    # queues is currently paused, there's nothing left to `BRPOP` at all
    # (an empty key list is invalid) — sleep out one `TIMEOUT` instead of
    # returning immediately, same pause `BRPOP` itself would have caused,
    # so `Processor#run`'s loop doesn't spin hot polling Redis in a tight
    # loop with no rate limit.
    def retrieve_work
      keys = active_keys
      if keys.empty?
        interruptible_sleep(TIMEOUT)
        return nil
      end

      result = Cogworker.config.redis { |c| c.brpop(*keys.shuffle, timeout: TIMEOUT) }
      return nil unless result

      queue_key, raw_job = result
      UnitOfWork.new(queue_key.delete_prefix(RedisKeys::QUEUE_PREFIX), raw_job)
    end

    # Nothing to do: BRPOP already removed the job from Redis.
    def acknowledge(_work); end

    # `Processor#interrupt`: the job ran, recording its failure failed —
    # file it under `set` (retry/dead) at `score` instead.
    def interrupt(_work, set, score, payload)
      Cogworker.config.redis { |c| c.zadd(set, score, payload) }
    end

    # Returns a fetched-but-unstarted job to the end of its queue that's
    # popped next.
    def give_back(work)
      Cogworker.config.redis { |c| c.rpush(RedisKeys.queue(work.queue), work.raw_job) }
    end

    # Shutdown past the drain timeout (`Manager#stop!`): the only record of
    # a still-running job is its `cogworker:workers:<identity>` entry, so
    # that's what gets pushed back — onto the end its queue is popped from,
    # so it runs next. Returns how many. One entry that can't be read is
    # logged and skipped, never allowed to cost the others their requeue.
    def self.requeue_in_progress(identity)
      Cogworker.config.redis do |c|
        c.hvals(RedisKeys.workers(identity)).count do |raw|
          entry = JSON.parse(raw)
          requeue_entry(c, entry.fetch('queue'), entry.fetch('payload'))
          true
        rescue StandardError => e
          Cogworker.logger.error { "couldn't requeue in-flight entry #{raw.to_s[0, 200]}: #{e.class}: #{e.message}" }
          false
        end
      end
    end

    def self.requeue_entry(conn, queue, job)
      queue_key = RedisKeys.queue(queue)
      retake = job['periodic_until_executed'] && job['periodic_pjid'] && job['jid']
      lock_key = retake ? RedisKeys.periodic_running(job['periodic_pjid']) : queue_key
      LuaScript.run(conn, REQUEUE_ENTRY_SCRIPT, keys: [queue_key, lock_key],
                                               argv: [JSON.generate(job), retake ? '1' : '0', job['jid'].to_s,
                                             Periodic::RunningLock.queued_ttl])
    end
    private_class_method :requeue_entry

    private

    def interruptible_sleep(seconds)
      deadline = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC) + seconds
      until @stopping.call
        left = deadline - ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
        break if left <= 0

        sleep([left, 0.25].min)
      end
    end

    def active_keys
      paused = Cogworker.config.redis { |c| c.smembers(RedisKeys::PAUSED_QUEUES) }
      return @queue_keys if paused.empty?

      @queue_keys.reject { |k| paused.include?(k.delete_prefix(RedisKeys::QUEUE_PREFIX)) }
    end

    UnitOfWork = Struct.new(:queue, :raw_job)

    # KEYS[1] = the queue, KEYS[2] = the job's periodic running lock (or the
    # queue again when there's none to take); ARGV[1] = payload, ARGV[2] =
    # "1" to re-take that lock, ARGV[3] = jid, ARGV[4] = lock TTL. Requeue
    # and lock in one step: as two commands, a failure in between left the
    # job queued without its lock (and miscounted).
    REQUEUE_ENTRY_SCRIPT = Periodic::RunningLock::RETAKE_FUNCTION + <<~LUA
      redis.call("RPUSH", KEYS[1], ARGV[1])
      if ARGV[2] == "1" then
        retake_running_lock(KEYS[2], ARGV[3], ARGV[4])
      end
      return 1
    LUA
  end
end
