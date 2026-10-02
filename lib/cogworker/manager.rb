# frozen_string_literal: true

module Cogworker
  # Owns the `concurrency`-sized thread pool of Processors for one OS
  # process, and the quiet/stop state they all poll.
  class Manager
    def initialize(config = Cogworker.config)
      @config = config
      @fetch_mutex = Mutex.new
      # This process's own record of its jobs (raw payloads, as fetched):
      # running right now (a count — two copies of one payload can run at
      # once), and finished but not yet settled in Redis — `:ack` (the ack
      # failed) or `[set, score, payload]` (the job ran and failed, and
      # filing it in retry/dead failed too). In memory on purpose:
      # ReliableFetch.reconcile trusts it over anything in Redis, which may
      # be what's failing (or what lost its last writes in a failover).
      @jobs_mutex = Mutex.new
      @running_jobs = Hash.new(0)
      @pending_settlements = {}
      @processors = Array.new(config.concurrency) { Processor.new(self) }
      @quiet = false
      @stopping = false
      @busy_mutex = Mutex.new
      @busy_count = 0
    end

    def queues
      @config.queues
    end

    # Resolved on first use, not in the constructor (that needed Redis
    # just to build a Manager). First use is normally the Heartbeat's first
    # beat; if Redis can't be reached then, ReliableFetch.supported? raises
    # and nothing is memoized — the beat fails and is retried, and this
    # resolves again next time — rather than memoizing a guess.
    def fetch_class
      @fetch_mutex.synchronize { @fetch_class ||= resolve_fetch_class }
    end

    # The server turned out not to support ReliableFetch after all
    # (ReliableFetch::UnsupportedError on a real fetch): every processor
    # switches to BasicFetch from its next fetch on. Safe, since no job can
    # be on the in-progress list — no LMOVE ever succeeded.
    def fall_back_to_basic_fetch!(error)
      @fetch_mutex.synchronize do
        next if @fetch_class == BasicFetch

        Cogworker.logger.warn do
          "config.fetch = :reliable isn't supported by this Redis (#{error.message[0, 120]}); " \
            'falling back to :basic (a job is lost if its process dies mid-job)'
        end
        @fetch_class = BasicFetch
      end
    end

    def start!
      @processors.each(&:start!)
    end

    def quiet!
      @quiet = true
    end

    def unquiet!
      @quiet = false
    end

    def quiet?
      @quiet
    end

    def stopping?
      @stopping
    end

    def job_started(raw)
      @jobs_mutex.synchronize { @running_jobs[raw] += 1 }
    end

    def job_finished(raw)
      @jobs_mutex.synchronize do
        @running_jobs[raw] -= 1
        @running_jobs.delete(raw) unless @running_jobs[raw].positive?
      end
    end

    def running_jobs
      @jobs_mutex.synchronize { @running_jobs.keys }
    end

    # `how`: :ack, or [set, score, payload] — see ReliableFetch.settle.
    def settle_later(raw, how)
      @jobs_mutex.synchronize { @pending_settlements[raw] = how }
    end

    def settled(raw)
      @jobs_mutex.synchronize { @pending_settlements.delete(raw) }
    end

    def pending_settlements
      @jobs_mutex.synchronize { @pending_settlements.dup }
    end

    def busy_count
      @busy_mutex.synchronize { @busy_count }
    end

    def processor_busy!
      @busy_mutex.synchronize { @busy_count += 1 }
    end

    def processor_idle!
      @busy_mutex.synchronize { @busy_count -= 1 }
    end

    # Waits (up to `timeout` seconds) for in-flight jobs to finish, then puts
    # any job still unfinished back on its queue and returns. Does not
    # force-kill lingering threads past the deadline — a thread stuck past
    # the deadline is the caller's (Launcher's) problem to decide whether to
    # hard-exit the process; its job is already safely requeued by then,
    # rather than lost with the process (it may therefore run twice, if the
    # thread does still finish it).
    def stop!(timeout: 25)
      @quiet = true
      @stopping = true
      deadline = monotonic_now + timeout
      @processors.each do |p|
        remaining = deadline - monotonic_now
        p.thread&.join([remaining, 0].max)
      end
      wait_for_fetching_processors
      requeue_unfinished
    end

    private

    # A processor that isn't running a job is at most one fetch timeout away
    # from noticing `stopping?` and exiting — but until it does, it can
    # still pop a job (BRPOP blocks for up to BasicFetch::TIMEOUT), and one
    # popped after `requeue_unfinished` had already run would be lost with
    # the process. Waiting those out first means the only threads left
    # alive are ones stuck inside a job, which never fetch again.
    def wait_for_fetching_processors
      deadline = monotonic_now + BasicFetch::TIMEOUT + 1
      @processors.reject(&:busy?).each do |p|
        p.thread&.join([deadline - monotonic_now, 0].max)
      end
    end

    # Jobs that finished but aren't settled in Redis yet are still on the
    # in-progress list. One more try at settling them first; then `except:`
    # drops the ones only waiting for their ack (which is what dropping
    # them is), in the same atomic step as requeueing the rest — a separate
    # ack pass that failed used to leave them to be requeued and run again.
    # Ones that couldn't be filed in retry/dead even now are handed over to
    # UNSETTLED for any live process to file later (ReliableFetch.park_unsettled)
    # — never requeued: they already ran. Any that can't even be handed
    # over are left on the list (`keep:`): orphan recovery requeues them
    # once this process is gone, at most `max_orphanings` times.
    def requeue_unfinished
      keep = []
      if fetch_class == ReliableFetch
        ReliableFetch.settle_pending(Cogworker.identity, pending_settlements) { |raw| settled(raw) }
        unfiled = pending_settlements.reject { |_raw, how| how == :ack }
        keep = ReliableFetch.park_unsettled(Cogworker.identity, unfiled)
        (unfiled.keys - keep).each { |raw| settled(raw) }
      end
      to_ack = pending_settlements.select { |_raw, how| how == :ack }.keys
      moved = fetch_class.requeue_in_progress(Cogworker.identity, except: to_ack, keep: keep)
      to_ack.each { |raw| settled(raw) }
      Cogworker.logger.warn { "requeued #{moved} job(s) unfinished at shutdown" } if moved.positive?
    rescue StandardError => e
      Cogworker.logger.error { "Requeueing unfinished jobs failed: #{e.class}: #{e.message}" }
    end

    def resolve_fetch_class
      return BasicFetch if @config.fetch == :basic
      return ReliableFetch if ReliableFetch.supported?

      Cogworker.logger.warn do
        "config.fetch = :reliable needs Redis >= #{ReliableFetch::MIN_REDIS_VERSION}; falling back to :basic " \
          '(a job is lost if its process dies mid-job)'
      end
      BasicFetch
    end

    # Fully qualified: inside the Cogworker namespace, a bare `Process` would
    # resolve to Cogworker::Process (the ProcessSet entry wrapper in api.rb),
    # not the ::Process kernel module.
    def monotonic_now
      ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
    end
  end
end
