# frozen_string_literal: true

module Cogworker
  # `Client.push`'s enqueue-mode switch, checked at the very end of the
  # client middleware chain in place of the real `raw_push` — the same spot
  # every enqueue path (`perform_async`/`perform_in`/`perform_at`, or a
  # direct `Client.push` call) already funnels through, so flipping this
  # mode covers all of them for free. Three states:
  #
  # - `:disabled` (default) — the real thing: pushes onto actual Redis, same
  #   as every non-test run. Nothing here changes any existing behavior.
  # - `:fake` — the client middleware chain still runs (so custom middleware
  #   that mutates the job hash, e.g. tagging, is exercised same as in prod),
  #   but the normalized job hash is appended to `jobs_for(klass_name)`
  #   instead of touching Redis — nothing is scheduled or executed. Use
  #   `SomeJob.jobs` (added to `Job::ClassMethods`) to assert what got
  #   pushed, `SomeJob.clear`/`Testing.clear_jobs!` to reset between
  #   examples.
  # - `:inline` — the job runs synchronously, right here in the calling
  #   thread, through the real server middleware chain
  #   (`Cogworker.config.server_chain`) — same as `Processor#execute`, minus
  #   the parts of that only make sense for an async worker process (work
  #   registration, stats counters, retry/dead routing on failure: there's
  #   no Processor here to retry anything later). An exception raised by
  #   `perform` propagates straight to the caller, same as calling
  #   `SomeJob.new.perform(*args)` directly would — this is a testing
  #   convenience, not a fire-and-forget execution path. `perform_in`/
  #   `perform_at`'s delay is ignored entirely; the job still runs
  #   immediately.
  #
  # A plain module-level ivar, not thread-local: this is a mode flipped once
  # in a test's setup, not a per-request runtime toggle — same single-
  # process assumption `Cogworker.config`/`Cogworker.server_process!` already
  # make.
  module Testing
    class << self
      def fake!(&block)
        set(:fake, &block)
      end

      def inline!(&block)
        set(:inline, &block)
      end

      def disable!(&block)
        set(:disabled, &block)
      end

      def fake?
        mode == :fake
      end

      def inline?
        mode == :inline
      end

      def disabled?
        mode == :disabled
      end

      def mode
        @mode ||= :disabled
      end

      # `SomeJob.jobs` reads this via `Job::ClassMethods#jobs` — every job
      # pushed for that exact class name while fake mode was on, oldest
      # first, as the same normalized (string-keyed) job hash `Client.push`
      # always produces (so `job['args']`/`job['at']`/`job['jid']` etc. all
      # work exactly as they would reading a job back out of Redis).
      def jobs_for(klass_name)
        registry[klass_name] ||= []
      end

      def clear_jobs!
        registry.clear
      end

      # Runs one job synchronously through the real server middleware chain.
      # Only ever called from `Client.push` while `inline?`.
      def perform_inline(job)
        klass = Object.const_get(job['class'])
        worker = klass.new
        worker.jid = job['jid'] if worker.respond_to?(:jid=)

        Cogworker.config.server_chain.invoke(worker, job, job['queue']) do
          worker.perform(*job['args'])
        end
      end

      private

      def registry
        @registry ||= {}
      end

      def set(new_mode)
        previous = mode
        @mode = new_mode
        return new_mode unless block_given?

        begin
          yield
        ensure
          @mode = previous
        end
      end
    end
  end
end
