# frozen_string_literal: true

module Cogworker
  # Multi-process supervisor: forks `COGWORKER_COUNT` worker children from
  # one parent (copy-on-write memory sharing) and relays signals to them.
  # `PHASED_RESTART=true` makes a restart trigger cycle children one at a
  # time (quiet -> wait -> replace) instead of all at once, so the pool as a
  # whole never has zero capacity.
  #
  # The parent process is never itself a job-processing Launcher — it only
  # forks/reaps/signals. Each child re-runs the full CLI boot (re-requiring
  # app code, resetting its own identity) *after* `fork`, never before, so
  # nothing in Heartbeat/Scheduled/the periodic Ticker ever starts a
  # background thread in the parent that would silently vanish in a child.
  class Swarm
    # How long a phased-restart replacement waits for the outgoing child to
    # exit on its own before giving up and force-killing it. Graceful
    # shutdown (Manager#stop! draining in-flight jobs) can legitimately take
    # a while, but this loop is single-threaded and blocking — one child
    # that never exits (a hung Redis call outliving even Manager#stop!'s
    # own 25s join, or anything else) must not be able to wedge the whole
    # restart cycle, and the supervisor's entire signal-handling loop with
    # it, forever.
    GRACEFUL_STOP_TIMEOUT = 20

    def initialize(argv, count: ENV.fetch('COGWORKER_COUNT', 1).to_i, phased: ENV['PHASED_RESTART'] == 'true')
      @argv = argv
      @count = [count, 1].max
      @phased = phased
      @children = {} # pid => slot index
      @signal_queue = ::Queue.new
      @stopping = false
    end

    def run
      install_signal_traps
      @count.times { |slot| fork_child(slot) }
      supervise
    end

    private

    def fork_child(slot)
      pid = ::Process.fork do
        Cogworker.reset_identity!
        CLI.new.run(@argv.dup)
        # `exit!`, not plain `exit`: `Launcher#run` only returns once
        # `Manager#stop!` has had its bounded (default 25s) chance to join
        # every processor thread — but per that method's own doc, a thread
        # stuck past its deadline (mid a hung Redis call, say) is left
        # running, not killed. A non-daemon thread still alive there would
        # make plain `exit`'s normal interpreter shutdown wait for it
        # indefinitely, so this OS process would never actually go away —
        # and `Swarm#initiate_restart`'s own `Process.waitpid(pid)` for this
        # exact child would then block forever right along with it.
        ::Process.exit!(true)
      end
      @children[pid] = slot
      Cogworker.logger.info { "swarm: started child pid=#{pid} slot=#{slot}" }
    end

    def install_signal_traps
      Signal.trap(Signals::QUIET) { @signal_queue << :quiet }
      Signal.trap(Signals::STOP) { @signal_queue << :stop }
      Signal.trap(Signals::INTERRUPT) { @signal_queue << :stop }
      Signal.trap(Signals::RESTART) { @signal_queue << :restart }
    end

    def supervise
      until @stopping && @children.empty?
        drain_signals
        reap_children
        sleep 0.2
      end
    end

    def drain_signals
      until @signal_queue.empty?
        case @signal_queue.pop
        when :quiet then relay(Signals::QUIET)
        when :stop then initiate_stop
        when :restart
          Cogworker.logger.info { "swarm: restart signal received, phased=#{@phased}" }
          initiate_restart
        else Cogworker.logger.warn { "Unknown signal: #{signal}" }
        end
      end
    end

    def relay(signal)
      @children.each_key { |pid| safe_kill(pid, signal) }
    end

    def initiate_stop
      @stopping = true
      relay(Signals::STOP)
    end

    # Non-phased: signal every child at once; the normal reap/respawn path
    # below brings each one back as it exits, so there's a brief capacity
    # dip but no explicit special-casing needed. Phased: replace children
    # one at a time, waiting for each replacement to finish forking before
    # touching the next, so total capacity never drops by more than one
    # slot at a time.
    def initiate_restart
      return relay(Signals::STOP) unless @phased

      @children.keys.each do |pid| # rubocop:disable Style/HashEachMethods -- mutates @children (delete/fork_child) during iteration; each_key is unsafe here
        next unless @children.key?(pid)

        slot = @children.delete(pid)
        Cogworker.logger.info { "swarm: phased restart stopping child pid=#{pid} slot=#{slot}" }
        safe_kill(pid, Signals::STOP)
        wait_for_exit(pid)
        Cogworker.logger.info { "swarm: phased restart child pid=#{pid} slot=#{slot} exited, respawning" }
        fork_child(slot)
      end
    end

    # Polls instead of a plain blocking `Process.waitpid(pid)`, specifically
    # so a child that never exits can't block this forever: past
    # GRACEFUL_STOP_TIMEOUT it's force-killed and reaped instead of leaving
    # `initiate_restart` (and every other signal this single-threaded
    # supervisor needs to handle) stuck behind it indefinitely.
    def wait_for_exit(pid)
      deadline = monotonic_now + GRACEFUL_STOP_TIMEOUT
      until ::Process.waitpid(pid, ::Process::WNOHANG)
        if monotonic_now > deadline
          Cogworker.logger.warn { "swarm: child pid=#{pid} didn't stop within #{GRACEFUL_STOP_TIMEOUT}s, killing" }
          safe_kill(pid, 'KILL')
          ::Process.waitpid(pid)
          return
        end
        sleep 0.1
      end
    rescue Errno::ECHILD
      nil
    end

    def monotonic_now
      ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
    end

    def reap_children
      pid = begin
        ::Process.waitpid(-1, ::Process::WNOHANG)
      rescue Errno::ECHILD
        nil
      end
      return unless pid

      slot = @children.delete(pid)
      return if slot.nil? # already handled by initiate_restart

      if @stopping
        Cogworker.logger.info { "swarm: child pid=#{pid} slot=#{slot} exited" }
      else
        Cogworker.logger.warn { "swarm: child pid=#{pid} slot=#{slot} exited unexpectedly, respawning" }
        fork_child(slot)
      end
    end

    def safe_kill(pid, signal)
      ::Process.kill(signal, pid)
    rescue Errno::ESRCH
      nil
    end
  end
end
