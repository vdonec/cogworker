# frozen_string_literal: true

module Cogworker
  # Boots one OS process: the Manager thread pool, the Scheduled poller, the
  # Heartbeat (+ remote quiet!/stop! subscriber), the periodic Ticker, and
  # standard signal handling (TSTP -> quiet, TERM/INT -> stop). This is the
  # method that must only ever run *after* a cogworkerswarm fork in a child,
  # never in the swarm parent itself before forking — see Heartbeat's note
  # on why.
  class Launcher
    def initialize(config = Cogworker.config)
      @config = config
      @manager = Manager.new(config)
      @scheduled = Scheduled.new(@manager)
      @heartbeat = Heartbeat.new(@manager)
      @ticker = Periodic::Ticker.new(
        @manager, config.periodic_manager.entries, catch_up: config.periodic_catch_up
      )
      @signal_queue = ::Queue.new
    end

    def run
      Cogworker.reset_identity!
      install_signal_traps
      resolve_periodic_classes
      @heartbeat.start! # first: see Heartbeat#start!
      @manager.start!
      @scheduled.start!
      @ticker.start!
      log_startup_info
      watch_signals
    end

    def quiet!
      @manager.quiet!
    end

    def stop!
      @manager.stop!
      @scheduled.stop!
      @ticker.stop!
      @heartbeat.stop!
    end

    private

    # Resolves every periodic entry's class here, on the main thread, before
    # any processor thread exists. `Processor#build_worker` otherwise does
    # the first `const_get` lazily on whichever processor thread picks the
    # job up — and with an app autoloader that isn't thread-safe, two
    # threads racing to autoload the same class (or its base class) can see
    # it half-defined (`undefined method 'perform'`). A class that can't be
    # resolved is only logged: every run of that entry will fail the same
    # way (and show up in Dead/History), but it shouldn't keep the rest of
    # the process from booting. Regular job classes aren't known up front —
    # eager-load the app in the init file for those (see README).
    def resolve_periodic_classes
      @config.periodic_manager.entries.map(&:class_name).uniq.each do |name|
        Object.const_get(name)
      rescue NameError => e
        Cogworker.logger.warn { "periodic job class #{name} can't be resolved: #{e.message}" }
      end
    end

    # Logged once all components are up, so the operator's console shows a
    # single summary (version/identity/pid/concurrency/queues/redis target)
    # right at the point the process is actually ready to pull work, rather
    # than scattered across each component's own start!.
    def log_startup_info
      Cogworker.logger.info do
        "Cogworker #{Cogworker::VERSION} started, identity=#{Cogworker.identity} pid=#{::Process.pid} " \
          "concurrency=#{@config.concurrency} queues=#{@config.queues.join(',')} redis=#{redis_target}"
      end
    end

    # Redacts a password/credential-bearing URL down to host/db so it's safe
    # to print — this is a startup banner, not a debug dump of secrets.
    def redis_target
      options = @config.redis_options
      if options[:url]
        options[:url].sub(%r{//[^@/]+@}, '//')
      else
        "#{options[:host] || 'localhost'}:#{options[:port] || 6379}/#{options[:db] || 0}"
      end
    end

    # Signal handlers must do as little as possible; all they do here is
    # push a symbol onto a Queue (safe from trap context) for the dedicated
    # watcher thread (see #watch_signals) to act on.
    def install_signal_traps
      Signal.trap(Signals::QUIET) { @signal_queue << :quiet }
      Signal.trap(Signals::STOP) { @signal_queue << :stop }
      Signal.trap(Signals::INTERRUPT) { @signal_queue << :stop }
    end

    def watch_signals
      loop do
        case @signal_queue.pop
        when :quiet
          Cogworker.logger.info { "Received quiet signal, identity=#{Cogworker.identity}" }
          quiet!
        when :stop
          Cogworker.logger.info { "Received stop signal, identity=#{Cogworker.identity}" }
          stop!
          break
        else
          Cogworker.logger.warn { "Received unknown signal, identity=#{Cogworker.identity}" }
        end
      end
    end
  end
end
