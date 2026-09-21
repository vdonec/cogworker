# frozen_string_literal: true

module Cogworker
  # Owns the `concurrency`-sized thread pool of Processors for one OS
  # process, and the quiet/stop state they all poll.
  class Manager
    def initialize(config = Cogworker.config)
      @config = config
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

    # Waits (up to `timeout` seconds) for in-flight jobs to finish, then
    # returns. Does not force-kill lingering threads past the deadline — a
    # thread stuck past the deadline is the caller's (Launcher's) problem to
    # decide whether to hard-exit the process.
    def stop!(timeout: 25)
      @quiet = true
      @stopping = true
      deadline = monotonic_now + timeout
      @processors.each do |p|
        remaining = deadline - monotonic_now
        p.thread&.join([remaining, 0].max)
      end
    end

    private

    # Fully qualified: inside the Cogworker namespace, a bare `Process` would
    # resolve to Cogworker::Process (the ProcessSet entry wrapper in api.rb),
    # not the ::Process kernel module.
    def monotonic_now
      ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
    end
  end
end
