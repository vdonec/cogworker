# frozen_string_literal: true

require 'json'
require 'redis'

module Cogworker
  # Publishes this process's presence (for ProcessSet) and listens for
  # remote quiet!/resume!/stop! requests (for Process#quiet!/#resume!/#stop!
  # issued by another process, e.g. a self-targeting WorkerKiller or the Web
  # UI). Both the
  # heartbeat loop and the pub/sub subscriber must only start *after* a
  # cogworkerswarm fork, never before, in the parent — otherwise the thread
  # simply doesn't exist in the child, and a lock that thread held could
  # leave the child permanently deadlocked.
  class Heartbeat
    INTERVAL = 5
    TTL = 60
    STARTUP_RETRY_INTERVAL = 1

    def initialize(manager)
      @manager = manager
    end

    # The first beat is synchronous, before any processor fetches a job:
    # ReliableFetch.recover_orphans treats an in-progress list with no live
    # heartbeat behind it as a dead process's, so this process must be
    # visibly alive before its own list can have anything on it. With Redis
    # unreachable, it keeps retrying (every STARTUP_RETRY_INTERVAL) rather
    # than letting the Manager start fetching with no presence key — until
    # it succeeds (returns true) or `abort_if` says to give up (returns
    # false, e.g. a stop signal arrived meanwhile; nothing is started then).
    def start!(abort_if: -> { false })
      @stopping = false
      until beat_safely
        return false if abort_if.call

        sleep(STARTUP_RETRY_INTERVAL)
      end
      @beat_thread = Thread.new { beat_loop }
      @signal_thread = Thread.new { subscribe_loop }
      true
    end

    # Tears down both background threads, not just the Redis keys — leaving
    # them running would leak a thread (and a dedicated pub/sub connection)
    # per Heartbeat instance for the remaining life of the process.
    #
    # The subscriber thread is killed *before* its connection is closed, and
    # never via `unsubscribe`: on redis-rb 4.x, `unsubscribe` from another
    # thread waits on the client's monitor, which the subscriber thread
    # holds for as long as it sits in its blocking read — so it hung
    # forever, and with it every `TERM`. Killing the thread releases the
    # monitor; closing the now-idle connection afterwards is safe on both
    # 4.x and 5.x.
    def stop!
      @stopping = true
      @beat_thread&.kill
      stop_subscriber!
      cleanup_presence!
    rescue StandardError
      nil
    end

    private

    def stop_subscriber!
      if @signal_thread && @signal_thread != Thread.current
        @signal_thread.kill
        @signal_thread.join(1)
      end
      @subscribe_client&.close
    rescue StandardError
      nil
    end

    def cleanup_presence!
      Cogworker.config.redis do |c|
        c.del(RedisKeys.process(Cogworker.identity), RedisKeys.workers(Cogworker.identity))
        c.srem?(RedisKeys::PROCESSES, Cogworker.identity)
        # Clean shutdown: Manager#stop! already requeued this process's
        # in-progress list, so there's nothing left for recovery to find.
        if c.llen(RedisKeys.in_progress(Cogworker.identity)).zero?
          c.srem?(RedisKeys::IN_PROGRESS_IDENTITIES, Cogworker.identity)
          c.hdel(RedisKeys::LAST_BEAT, Cogworker.identity)
        end
      end
    end

    # A failed beat (Redis blip, failover) is logged and retried on the next
    # interval, never allowed to end the loop: a dead heartbeat thread
    # meant this process silently vanished from ProcessSet/the Workers tab
    # once its TTL ran out, while still running jobs.
    def beat_loop
      loop do
        sleep(INTERVAL)
        beat_safely
      end
    end

    def beat_safely
      beat
      @beat_failed = false
      RedisErrors.recovered('Heartbeat')
      true
    rescue StandardError => e
      @beat_failed = true
      RedisErrors.report('Heartbeat', e)
      false
    end

    def beat
      identity = Cogworker.identity
      reliable = @manager.fetch_class == ReliableFetch
      info = {
        'hostname' => Cogworker.hostname,
        'pid' => ::Process.pid,
        'concurrency' => Cogworker.config.concurrency,
        'queues' => @manager.queues,
        'started_at' => (@started_at ||= Time.now.to_f),
        'rss_kb' => current_rss_kb
      }

      # The presence key is what makes this process alive to everyone else
      # (and what Heartbeat#start! waits for) — the one write a beat can't
      # do without. Everything else is written on its own, best-effort: one
      # shared key of the wrong type used to fail every beat of every
      # process, so no new process could start anywhere in the fleet.
      Cogworker.config.redis do |c|
        c.hset(RedisKeys.process(identity),
               'info', JSON.generate(info),
               'busy', @manager.busy_count.to_s,
               'quiet', @manager.quiet?.to_s)
        c.expire(RedisKeys.process(identity), TTL)
        write_registries(c, identity, reliable)
        touch_running_periodic_locks(c, identity)
        # Not via #secondary: Redis failing here, after the presence key went
        # through, doesn't make this beat a failed one.
        BestEffort.call('Deferred lock releases') { DeferredReleases.retry_all(c) }
      end
    end

    # Everything a beat writes besides the presence key — each on its own,
    # best-effort (see #secondary).
    def write_registries(conn, identity, reliable)
      secondary('process registry') { conn.sadd?(RedisKeys::PROCESSES, identity) }
      # The queues this process reads are listed even while empty: the Web
      # UI shows them, and recovery can tell a queue nobody reads from one
      # that's merely had nothing pushed yet.
      secondary('queue registry') { conn.sadd(RedisKeys::QUEUES, @manager.queues.uniq) }
      secondary('live queue registry') { mark_queues_live(conn) }
      secondary('workers expiry') { conn.expire(RedisKeys.workers(identity), TTL) }
      return unless reliable

      secondary('in-progress registry') { conn.sadd?(RedisKeys::IN_PROGRESS_IDENTITIES, identity) }
      secondary('last-beat stamp') { conn.hset(RedisKeys::LAST_BEAT, identity, redis_now(conn)) }
    end

    # Stamps this process's queues as read right now, and drops ones no
    # process has stamped for a day (only ever a listing, never data).
    def mark_queues_live(conn)
      now = redis_now(conn)
      conn.zadd(RedisKeys::LIVE_QUEUES, @manager.queues.uniq.map { |q| [now, q] })
      conn.zremrangebyscore(RedisKeys::LIVE_QUEUES, '-inf', now - 86_400)
    end

    def secondary(what)
      yield
    rescue StandardError => e
      raise if RedisErrors.unavailable?(e) # Redis itself is away: the beat as a whole failed

      Cogworker.logger.error { "Heartbeat: #{what} not written: #{e.class}: #{e.message}" }
    end

    # Redis's clock, not this host's (so host clock skew doesn't matter to
    # orphan detection) — falling back to this host's where `TIME` isn't
    # allowed (some proxies/managed services): better a skewed stamp than a
    # process that can never complete its first beat.
    def redis_now(conn)
      conn.time.first
    rescue Redis::CommandError
      Time.now.to_i
    end

    # Keeps every in-flight `until_executed` periodic run's
    # `periodic:running:<pjid>` lock alive for as long as this process is —
    # see Periodic::RunningLock. From the Manager's own in-memory record of
    # what's running here, not `cogworker:workers` in Redis: a failover that
    # lost that Hash would otherwise let a long run's lock lapse mid-run.
    # (One narrow race remains: a release landing between this beat's
    # snapshot of `performing_jobs` and its Lua call, on the first beat
    # after a failed one, can be undone — the lock then lapses on
    # `active_ttl`. Not worth a cross-thread lock on every beat.)
    # Only jobs still inside `perform` (`performing_jobs`): once it returns,
    # Periodic::ReleaseMiddleware has released the lock, and refreshing it
    # again would bring it back. A missing lock is only *re-taken* on the
    # first beat after a failed one — i.e. after Redis was away, possibly
    # long enough for the lock to lapse; otherwise a missing lock means it
    # was released, and stays released.
    def touch_running_periodic_locks(conn, _identity)
      recovering = @beat_failed
      @manager.performing_jobs.each do |raw|
        job = JSON.parse(raw)
        next unless job.is_a?(Hash) && job['periodic_pjid']

        if recovering && job['periodic_until_executed']
          # Re-taken, not just extended: after Redis was away longer than
          # `active_ttl`, the lock is gone while the run is still going, and
          # the ticker could start the next slot alongside it.
          Periodic::RunningLock.retake(job['periodic_pjid'], job['jid'], Periodic::RunningLock.active_ttl, conn)
        else
          Periodic::RunningLock.touch(job['periodic_pjid'], job['jid'], Periodic::RunningLock.active_ttl, conn)
        end
      rescue StandardError => e
        # Per entry: one bad entry mustn't leave the others' locks to expire.
        Cogworker.logger.error { "couldn't refresh periodic lock for #{raw.to_s[0, 200]}: #{e.class}: #{e.message}" }
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
        on.subscribe { |*| RedisErrors.recovered('Signal subscriber') }
        on.message do |_channel, message|
          dispatch(message)
        end
      end
    rescue StandardError => e
      return if @stopping

      RedisErrors.report('Signal subscriber', e)
      sleep(1)
      retry
    end

    def dispatch(message)
      case message
      when 'quiet' then @manager.quiet!
      when 'resume' then @manager.unquiet!
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
      Cogworker.flush_output!
      ::Process.exit!(true)
    end
  end
end
