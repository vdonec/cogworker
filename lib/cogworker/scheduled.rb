# frozen_string_literal: true

require 'json'

module Cogworker
  # Background poller: moves due jobs from the `cogworker:schedule` and
  # `cogworker:retry` ZSETs into their target queue. Safe with many processes
  # polling concurrently: `ZREM` returning 1 (vs 0) is the atomic "I won the
  # race to graduate this job" signal — the same pattern the periodic
  # scheduler's Lua claim later builds on for its own exactly-once guarantee.
  class Scheduled
    SETS = [RedisKeys::SCHEDULE, RedisKeys::RETRY].freeze
    POLL_INTERVAL = 5
    # How often this poller also looks for jobs left in progress by a dead
    # process (ReliableFetch.recover_orphans) — the first time right away,
    # at boot. Every live process does it, whatever its own fetch mode: in
    # a mixed fleet, or after a runtime fall-back to `:basic`, the lists of
    # crashed reliable processes still need someone to requeue them, and
    # with nothing registered it's a single SMEMBERS. Only the one-off
    # keyspace SCAN (for lists from before IN_PROGRESS_IDENTITIES existed)
    # is limited to processes actually using ReliableFetch. The requeue is
    # atomic, so any number of processes doing it at once is safe.
    ORPHAN_CHECK_INTERVAL = 60

    # KEYS[1] = the ZSET, KEYS[2] = cogworker:dead, KEYS[3] = stats:failed;
    # ARGV[1] = the entry, ARGV[2] = its dead-set score, ARGV[3] = the
    # wrapper to store. Same claim-and-move-atomically shape as
    # JobUtil::CLAIM_AND_REQUEUE_SCRIPT.
    BURY_SCRIPT = <<~LUA
      if redis.call("ZREM", KEYS[1], ARGV[1]) == 0 then
        return 0
      end
      redis.call("ZADD", KEYS[2], ARGV[2], ARGV[3])
      redis.call("INCR", KEYS[3])
      return 1
    LUA

    def initialize(manager)
      @manager = manager
    end

    def start!
      @thread = Thread.new { run }
    end

    # Killed outright, not gracefully joined: unlike a Processor (which may
    # be mid-job), this thread only ever holds the GVL briefly between one
    # POLL_INTERVAL sleep and the next, so there's nothing to drain. Without
    # this, the thread would only notice `@manager.stopping?` after waking
    # from its own up-to-5s sleep — and since it's a non-daemon thread, the
    # OS process can't actually exit until then, which a caller blocked on a
    # plain (no-timeout) `Process.waitpid` for this process — Swarm's
    # phased restart — would otherwise just sit stuck behind.
    def stop!
      @thread&.kill
    end

    private

    # A failed poll is logged and retried next interval rather than ending
    # the thread — a single Redis blip used to stop every scheduled/retry
    # job in this process from ever reaching its queue again.
    def run
      until @manager.stopping?
        begin
          recover_orphans_if_due
          enqueue_due_jobs unless @manager.quiet?
        rescue StandardError => e
          Cogworker.logger.error { "Scheduled poll failed: #{e.class}: #{e.message}" }
        end
        sleep(POLL_INTERVAL)
      end
    end

    def recover_orphans_if_due
      now = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
      return if @next_orphan_check && now < @next_orphan_check

      scan = @next_orphan_check.nil? && @manager.fetch_class == ReliableFetch
      @next_orphan_check = now + ORPHAN_CHECK_INTERVAL
      ReliableFetch.recover_orphans(scan: scan)
    end

    def enqueue_due_jobs
      now = Time.now.to_f
      SETS.each do |set|
        candidates = Cogworker.config.redis { |c| c.zrangebyscore(set, '-inf', now, limit: [0, 50]) }
        candidates.each { |raw| graduate(set, raw) }
      end
    end

    # An entry that can't be requeued (not JSON, no queue) is buried in
    # `dead` instead: left in place it would sit first by score, failing
    # every poll and starving everything behind it; raising after the
    # `zrem` used to lose it silently (and cut the rest of this poll short).
    def graduate(set, raw)
      Cogworker.config.redis do |c|
        next unless JobUtil.claim_and_requeue(c, set, raw) == :invalid

        bury(c, set, raw)
      end
    end

    def bury(conn, set, raw)
      error = JSON::ParserError.new("not a job (JSON object with a queue) in #{set}")
      job = JobUtil.unparseable_job(raw, queue: nil, error: error)
      buried = conn.eval(BURY_SCRIPT, keys: [set, RedisKeys::DEAD, RedisKeys::STATS_FAILED],
                                      argv: [raw, job['failed_at'], JSON.generate(job)])
      return unless buried == 1

      Throughput.record('failed') # counted like Processor#bury_unparseable
      Cogworker.logger.error { "unparseable entry in #{set} moved to dead: #{raw.to_s[0, 200]}" }
    end
  end
end
