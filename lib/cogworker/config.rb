# frozen_string_literal: true

module Cogworker
  # Process-global configuration, built once and mutated in place by
  # (possibly several, per the real init code) `configure_server`/
  # `configure_client` calls, so every block sees and extends the same
  # server/client middleware chains.
  class Config
    attr_reader :server_chain, :client_chain, :periodic_manager, :redis_options
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
      register_default_middleware
    end

    def redis=(options)
      @redis_options = options
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
    def periodic(&block)
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
