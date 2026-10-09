# frozen_string_literal: true

module Cogworker
  # Process-global configuration, built once and mutated in place by
  # (possibly several, per the real init code) `configure_server`/
  # `configure_client` calls, so every block sees and extends the same
  # server/client middleware chains.
  class Config
    FETCH_MODES = %i[reliable basic].freeze

    attr_reader :server_chain, :client_chain, :periodic_manager, :redis_options, :fetch, :fetch_idle_max_interval,
                :orphan_threshold, :max_orphanings, :periodic_replace, :death_handlers
    attr_accessor :concurrency, :queues, :periodic_catch_up, :unique_lock_ttl

    def initialize
      @server_chain = Middleware::Chain.new
      @client_chain = Middleware::Chain.new
      @periodic_manager = Periodic::Manager.new
      @redis_options = {}
      @concurrency = 10
      @queues = ['default']
      # Default true: an entry's most-recently-due slot fires immediately on
      # a process's first tick, same as always. Set to false to skip that
      # one-time catch-up fire instead — see Periodic::Ticker#priming_first_slot?
      # for why a cold start against an empty/reset Redis otherwise fires
      # every registered entry at once.
      @periodic_catch_up = true
      # Safety-net TTL (seconds) on a regular `unique: :until_executed`
      # job's lock — `UniqueJobs::ReleaseMiddleware` is what actually clears
      # it on success/terminal failure; this only bounds how long a lock
      # can stay stuck if a process dies mid-job before that ever runs
      # (same class of gap as a crashed process losing its in-flight job
      # generally — see the Status section of CLAUDE.md). 24h by default;
      # set higher/lower to match how long a unique job might legitimately
      # run plus however long its retries can take.
      @unique_lock_ttl = 24 * 60 * 60
      # How processors take jobs off their queues — `:reliable` (ReliableFetch,
      # needs Redis >= 6.2; a job survives its process dying) or `:basic`
      # (BasicFetch, one blocking BRPOP; a job is lost if its process dies).
      # On an older Redis, `:reliable` falls back to `:basic` with a warning
      # (Manager#resolve_fetch_class).
      @fetch = :reliable
      # Longest pause (seconds) ReliableFetch makes between polls of empty
      # queues — the worst-case delay before an idle worker notices a new
      # job. See ReliableFetch::EMPTY_POLL_INTERVAL.
      @fetch_idle_max_interval = 1.0
      # How long (seconds) a process must have gone without a heartbeat
      # before ReliableFetch.recover_orphans treats it as dead and requeues
      # its in-progress jobs. Higher: fewer false "dead" verdicts on a live
      # process that merely couldn't beat for a while (a Redis outage or
      # failover, a long GVL-holding call) — each of which runs its jobs
      # twice; lower: a really crashed process's jobs come back sooner.
      @orphan_threshold = 300
      # How many times a job may be recovered from a process that died
      # while running it before it goes to dead instead (ReliableFetch). The
      # count can't single out the culprit: every job running in a process
      # that crashed is counted, so keep this above the number of crashes an
      # innocent job might plausibly sit through.
      @max_orphanings = 3
      # Callables `(job, exception)` run, after the job class's own
      # `cogworker_retries_exhausted`, whenever a job lands in dead for good
      # (DeathNotifier). `config.death_handlers << ->(job, e) { ... }`.
      @death_handlers = []
      register_default_middleware
    end

    def max_orphanings=(count)
      unless count.is_a?(Integer) && count.positive?
        raise ArgumentError,
              "max_orphanings must be a positive Integer, got #{count.inspect}"
      end

      @max_orphanings = count
    end

    def orphan_threshold=(seconds)
      unless seconds.is_a?(Numeric) && seconds.positive?
        raise ArgumentError, "orphan_threshold must be a positive number of seconds, got #{seconds.inspect}"
      end

      @orphan_threshold = seconds
    end

    def fetch_idle_max_interval=(seconds)
      unless seconds.is_a?(Numeric) && seconds.positive?
        raise ArgumentError, "fetch_idle_max_interval must be a positive number of seconds, got #{seconds.inspect}"
      end

      @fetch_idle_max_interval = seconds
    end

    def fetch=(mode)
      resolved = mode.to_s.to_sym
      unless FETCH_MODES.include?(resolved)
        raise ArgumentError, "fetch must be one of #{FETCH_MODES.join(', ')}, got #{mode.inspect}"
      end

      @fetch = resolved
    end

    # Also drops an already-built pool: `redis_pool` is memoized on first
    # use, so without this a `redis =` after anything had touched Redis
    # (an init file configuring twice, a test switching databases) was
    # silently ignored. The old pool's connections are closed as they're
    # checked back in, so a caller still holding one finishes normally.
    def redis=(options)
      @redis_options = options
      old_pool = @redis_pool
      @redis_pool = nil
      old_pool&.shutdown(&:close)
    end

    def redis_pool
      @redis_pool ||= RedisConnection.create(@redis_options.merge(size: concurrency + 5))
    end

    def redis(&block)
      pool = redis_pool
      if block_given?
        pool.with(&block)
      else
        pool
      end
    end

    def server_middleware
      yield server_chain if block_given?
      server_chain
    end

    def client_middleware
      yield client_chain if block_given?
      client_chain
    end

    # `config.periodic(&PERIODIC_JOBS)` — the block receives the manager and
    # registers cron entries synchronously as it runs. No-op-safe: an app
    # that never calls this simply has an empty periodic_manager, and the
    # Ticker (started later, per process) has nothing to do.
    #
    # `replace: true` clears what earlier calls registered first, and makes
    # the Ticker replace the whole published `periodic:schedule` rather than
    # adding to it — so an entry deleted from (or changed in) the schedule
    # file disappears from the Web UI instead of lingering there forever.
    # Opt-in: with processes that register *different* schedules against one
    # Redis, each would wipe the others' entries off the Schedules tab.
    def periodic(replace: false, &block)
      if replace
        periodic_manager.clear!
        @periodic_replace = true
      end
      block&.call(periodic_manager)
      periodic_manager
    end

    private

    # Always present, regardless of whether config.periodic/a unique job is
    # ever used — each is a no-op for a job that doesn't carry its own
    # marker (`periodic_pjid`/`unique: :until_executed`).
    def register_default_middleware
      @server_chain.add(Periodic::ReleaseMiddleware)
      @client_chain.add(UniqueJobs::ClientMiddleware)
      @server_chain.add(UniqueJobs::ReleaseMiddleware)
    end
  end
end
