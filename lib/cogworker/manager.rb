# frozen_string_literal: true

module Cogworker
  # Owns the `concurrency`-sized thread pool of Processors for one OS
  # process, and the quiet/stop state they all poll.
  class Manager
    attr_reader :fetch_class

    def initialize(config = Cogworker.config)
      @config = config
      @fetch_class = resolve_fetch_class
      @processors = Array.new(config.concurrency) { Processor.new(self) }
      @quiet = false
      @stopping = false
      @busy_mutex = Mutex.new
      @busy_count = 0
    end

    def queues
      @config.queues
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

    def requeue_unfinished
      moved = @fetch_class.requeue_in_progress(Cogworker.identity)
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
