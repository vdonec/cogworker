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
    DEFER_DELAY = 60

    # KEYS[1] = the ZSET, KEYS[2] = cogworker:dead, KEYS[3] = stats:failed;
    # ARGV[1] = the entry, ARGV[2] = its dead-set score, ARGV[3] = the
    # wrapper to store. Same claim-and-move-atomically shape as
    # JobUtil::CLAIM_AND_REQUEUE_SCRIPT.
    # (Write, then remove — see JobUtil::CLAIM_AND_REQUEUE_SCRIPT; the stats
    # counter is best-effort.)
    BURY_SCRIPT = <<~LUA
      if not redis.call("ZSCORE", KEYS[1], ARGV[1]) then
        return 0
      end
      redis.call("ZADD", KEYS[2], ARGV[2], ARGV[3])
      redis.call("ZREM", KEYS[1], ARGV[1])
      redis.pcall("INCR", KEYS[3])
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

    # True once the first orphan check has completed — what the periodic
    # Ticker waits for before its first tick (see Launcher#initialize).
    def recovered_once?
      @recovered_once == true
    end

    # What the periodic Ticker waits for before its first tick: the first
    # orphan check that really completed. No timeout: without Redis the
    # Ticker couldn't do anything anyway, and a key that would keep the check
    # failing for good is quarantined (KeyGuard) within a minute — whereas
    # starting early after a long outage could run an `until_executed` slot
    # alongside the recovered run of the previous one.
    def ready_for_ticker?
      recovered_once?
    end

    private

    # A failed poll is logged and retried next interval rather than ending
    # the thread — a single Redis blip used to stop every scheduled/retry
    # job in this process from ever reaching its queue again.
    # Recovery and graduating due jobs fail independently: a recovery that
    # keeps failing used to skip `enqueue_due_jobs` on every poll, so no
    # scheduled or retried job reached its queue anywhere in the fleet.
    def run
      until @manager.stopping?
        guarded('Key check') { check_keys_if_due }
        guarded('Orphan check') { recover_orphans_if_due }
        guarded('Scheduled poll') { enqueue_due_jobs unless @manager.quiet? }
        sleep(POLL_INTERVAL)
      end
    end

    # An entry that can't be graduated right now (its queue key of the wrong
    # type, say) is pushed DEFER_DELAY into the future: left due, it would be
    # one of the same oldest 50 picked again on every poll, and enough of
    # them would starve everything behind them for good.
    def defer(set, raw, error)
      Cogworker.logger.error { "Graduating an entry of #{set} failed (deferred #{DEFER_DELAY}s): #{error.class}: #{error.message}" }
      Cogworker.config.redis { |c| c.zadd(set, Time.now.to_f + DEFER_DELAY, raw, xx: true) }
    rescue StandardError => e
      Cogworker.logger.error { "Deferring it failed too: #{e.class}: #{e.message}" }
    end

    def guarded(what)
      yield
    rescue StandardError => e
      Cogworker.logger.error { "#{what} failed: #{e.class}: #{e.message}" }
    end

    # The next check is scheduled before this one runs: one that keeps
    # failing (everything inside it is isolated, so that means Redis itself
    # is failing) is retried every ORPHAN_CHECK_INTERVAL — or on the next
    # poll if it lost the connection — never on every poll with a full SCAN.
    # The one-off SCAN only counts as done once it has succeeded.
    def recover_orphans_if_due
      now = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
      return if @next_orphan_check && now < @next_orphan_check

      @next_orphan_check = now + ORPHAN_CHECK_INTERVAL
      reliable = @manager.fetch_class == ReliableFetch
      report = {}
      # Lost the connection (anywhere in it): check again on the next poll,
      # not a minute later — Redis coming back is when it matters most.
      begin
        ReliableFetch.recover_orphans(scan: reliable && !@scanned, report: report)
      rescue Redis::BaseConnectionError
        @next_orphan_check = now + POLL_INTERVAL
        raise
      end
      @next_orphan_check = now + POLL_INTERVAL if report[:connection_lost]
      guarded('Reconcile') { reconcile } if reliable
      # Only once that actually looked: a pass that merely survived every
      # error (recovery isolates them), or lost the connection part-way,
      # mustn't let the Ticker start, nor count the one-off SCAN as done.
      return if report[:connection_lost]

      @scanned = true if report[:scan]
      @recovered_once = true if report[:registry] || report[:scan]
    end

    # See KeyGuard. First thing on the first poll, then every
    # KeyGuard::CHECK_INTERVAL — before recovery and polling, so a key that
    # would break them is already out of the way.
    def check_keys_if_due
      now = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
      return if @next_key_check && now < @next_key_check

      @next_key_check = now + KeyGuard::CHECK_INTERVAL
      KeyGuard.check(queues: @manager.queues)
    end

    def reconcile
      @strays = ReliableFetch.reconcile(Cogworker.identity, @strays || [],
                                        running: @manager.running_jobs, pending: @manager.pending_settlements) do |raw|
        @manager.settled(raw)
      end
    end

    # Each set, and each entry, on its own: `schedule` unreadable mustn't
    # stop `retry` from being polled, nor one entry whose graduation fails
    # stop the rest of the batch.
    def enqueue_due_jobs
      now = Time.now.to_f
      SETS.each do |set|
        guarded("Polling #{set}") do
          candidates = Cogworker.config.redis { |c| c.zrangebyscore(set, '-inf', now, limit: [0, 50]) }
          candidates.each do |raw|
            graduate(set, raw)
          rescue StandardError => e
            defer(set, raw, e)
          end
        end
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
      buried = LuaScript.run(conn, BURY_SCRIPT, keys: [set, RedisKeys::DEAD, RedisKeys::STATS_FAILED],
                                               argv: [raw, job['failed_at'], JSON.generate(job)])
      return unless buried == 1

      Throughput.record('failed') # counted like Processor#bury_unparseable
      Cogworker.logger.error { "unparseable entry in #{set} moved to dead: #{raw.to_s[0, 200]}" }
    end
  end
end
