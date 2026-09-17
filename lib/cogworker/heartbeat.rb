# frozen_string_literal: true

require 'json'
require 'redis'

module Cogworker
  # Publishes this process's presence (for ProcessSet) and listens for
  # remote quiet!/stop! requests (for Process#quiet!/#stop! issued by another
  # process, e.g. a self-targeting WorkerKiller or the Web UI). Both the
  # heartbeat loop and the pub/sub subscriber must only start *after* a
  # cogworkerswarm fork, never before, in the parent — otherwise the thread
  # simply doesn't exist in the child, and a lock that thread held could
  # leave the child permanently deadlocked.
  class Heartbeat
    INTERVAL = 5
    TTL = 60

    def initialize(manager)
      @manager = manager
    end

    def start!
      @stopping = false
      @beat_thread = Thread.new { beat_loop }
      @signal_thread = Thread.new { subscribe_loop }
    end

    # Tears down both background threads, not just the Redis keys — leaving
    # them running would leak a thread (and a dedicated pub/sub connection)
    # per Heartbeat instance for the remaining life of the process.
    def stop!
      @stopping = true
      @beat_thread&.kill
      @subscribe_client&.unsubscribe
      @signal_thread&.kill
      cleanup_presence!
    rescue StandardError
      nil
    end

    private

    def cleanup_presence!
      Cogworker.config.redis do |c|
        c.del(RedisKeys.process(Cogworker.identity), RedisKeys.workers(Cogworker.identity))
        c.srem(RedisKeys::PROCESSES, Cogworker.identity)
      end
    end

    def beat_loop
      loop do
        beat
        sleep(INTERVAL)
      end
    rescue StandardError => e
      Cogworker.logger.error { "Heartbeat died: #{e.class}: #{e.message}" }
    end

    def beat
      identity = Cogworker.identity
      info = {
        'hostname' => Cogworker.hostname,
        'pid' => ::Process.pid,
        'concurrency' => Cogworker.config.concurrency,
        'queues' => @manager.queues,
        'started_at' => (@started_at ||= Time.now.to_f),
        'rss_kb' => current_rss_kb
      }

      Cogworker.config.redis do |c|
        c.sadd(RedisKeys::PROCESSES, identity)
        c.hset(RedisKeys.process(identity),
               'info', JSON.generate(info),
               'busy', @manager.busy_count.to_s,
               'quiet', @manager.quiet?.to_s)
        c.expire(RedisKeys.process(identity), TTL)
        c.expire(RedisKeys.workers(identity), TTL)
      end
    end

    # Current resident set size, in KB — read straight from the kernel
    # (`/proc/self/status`, present on any real Linux deployment target)
    # when available, since that's a plain file read with no extra process;
    # `ps` (a real fork+exec every heartbeat) is only the fallback for
    # platforms without `/proc` (macOS in local dev). `nil` — not `0` — on
    # any failure, so the Web UI can render "n/a" rather than a misleading
    # "0M" if this ever can't be measured.
    def current_rss_kb
      proc_status = '/proc/self/status'
      if File.readable?(proc_status)
        matched = File.read(proc_status)[/^VmRSS:\s+(\d+)\s+kB/, 1]
        return matched.to_i if matched
      end

      out = `ps -o rss= -p #{::Process.pid} 2>/dev/null`.strip
      out.empty? ? nil : out.to_i
    rescue StandardError
      nil
    end

    # Uses its own dedicated (non-pooled) Redis client: SUBSCRIBE blocks the
    # connection for as long as the subscription is open, which would starve
    # the shared job-execution pool if it borrowed a connection from there.
    def subscribe_loop
      @subscribe_client = ::Redis.new(RedisConnection.client_options(Cogworker.config.redis_options))
      @subscribe_client.subscribe(RedisKeys.signal(Cogworker.identity)) do |on|
        on.message do |_channel, message|
          dispatch(message)
        end
      end
    rescue StandardError => e
      return if @stopping

      Cogworker.logger.error { "Signal subscriber died: #{e.class}: #{e.message}" }
      sleep(1)
      retry
    end

    def dispatch(message)
      case message
      when 'quiet' then @manager.quiet!
      when 'stop' then remote_stop!
      else Cogworker.logger.warn { "Unknown signal message: #{message}" }
      end
    end

    # A *remote* stop (published by another process — typically the Web
    # UI's `Process#stop!` — as opposed to this process's own `TERM`/`INT`,
    # handled by `Launcher#stop!`/`#watch_signals` on the main thread) has
    # to actually end this OS process, not just quiesce the Manager
    # forever: nothing here naturally returns from a running `Launcher#run`
    # loop the way breaking out of `watch_signals` does — this dispatch
    # runs on the pub/sub subscriber's own background thread, so without an
    # explicit exit the process would otherwise sit there, still
    # heartbeating, permanently "quiet", never picking up work again,
    # until someone `kill`s it for real or the swarm is restarted.
    # `::Process.exit!` (not `Kernel#exit`, which only raises `SystemExit`
    # on the *calling* thread and wouldn't actually end the process from
    # here) terminates immediately and unconditionally, from any thread —
    # deliberately *after* `@manager.stop!` has already drained in-flight
    # work and `cleanup_presence!` has already removed this process from
    # Redis, so both happen before the process can vanish out from under
    # them.
    def remote_stop!
      @manager.stop!
      cleanup_presence!
      ::Process.exit!(true)
    end
  end
end
