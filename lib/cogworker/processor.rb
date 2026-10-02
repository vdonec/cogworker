# frozen_string_literal: true

require 'json'
require 'securerandom'

module Cogworker
  # One thread of a Manager's pool: fetch -> register in-flight -> run the
  # server middleware chain around perform -> stats/retry -> deregister.
  class Processor
    ERROR_BACKOFF = 1 # seconds
    ACK_ATTEMPTS = 3

    attr_reader :thread, :tid

    def initialize(manager)
      @manager = manager
      @busy = false
      @tid = SecureRandom.hex(6)
    end

    def start!
      @thread = Thread.new { run }
    end

    # True while executing a job (as opposed to fetching or idle) — what
    # `Manager#stop!` uses to tell a thread that will exit on its own within
    # one fetch timeout from one stuck in a long job.
    def busy?
      @busy
    end

    private

    # An error escaping one iteration (a Redis blip in `retrieve_work` or
    # the in-flight bookkeeping) is logged and the loop carries on after
    # ERROR_BACKOFF — it used to end the thread for good, with nothing ever
    # restarting it, so the process silently lost capacity one slot at a
    # time.
    def run
      until @manager.stopping?
        begin
          process_one
        rescue StandardError => e
          Cogworker.logger.error { "Processor error: #{e.class}: #{e.message}" }
          sleep(ERROR_BACKOFF)
        end
      end
    end

    def process_one
      if @manager.quiet?
        sleep(0.5)
        return
      end

      work = begin
        fetcher.retrieve_work
      rescue ReliableFetch::UnsupportedError => e
        @manager.fall_back_to_basic_fetch!(e)
        @fetcher = nil
        return
      end
      return unless work

      # Fetched after shutdown began (e.g. still blocked in BRPOP when
      # `Manager#stop!` requeued unfinished work, which it then popped right
      # back): hand it back rather than start it, since the process is about
      # to exit underneath it.
      return fetcher.give_back(work) if @manager.stopping?

      @manager.processor_busy!
      @busy = true
      finished = false
      begin
        execute(work)
        finished = true
      ensure
        @busy = false
        @manager.processor_idle!
        finished ? acknowledge(work) : give_back(work)
      end
    end

    # `execute` raising means bookkeeping failed (Redis, mid-way through
    # registering the job or routing its failure to retry/dead) — not the
    # job itself, whose own errors `execute` always handles. Acknowledging
    # here would drop a job that never made it to retry/dead; instead it
    # goes straight back on its queue (it may run again: at-least-once). If
    # even that fails, it simply stays on the in-progress list, which
    # `Manager#stop!`/orphan recovery requeue later.
    def give_back(work)
      fetcher.give_back(work)
    rescue StandardError => e
      Cogworker.logger.error do
        "couldn't hand back jid=#{jid_of(work)} after a failed run (left in progress): #{e.class}: #{e.message}"
      end
    end

    # A failed ack leaves an already-finished job on this process's own
    # in-progress list, where `Manager#stop!` would later requeue it — a
    # silent second run. Retried briefly, then logged with the jid so that
    # duplicate can at least be traced.
    def acknowledge(work)
      attempts = 0
      begin
        attempts += 1
        fetcher.acknowledge(work)
      rescue StandardError => e
        if attempts < ACK_ATTEMPTS
          sleep(0.1 * attempts)
          retry
        end
        Cogworker.logger.error do
          "couldn't acknowledge finished job jid=#{jid_of(work)} after #{attempts} attempts " \
            "(it may run again on shutdown): #{e.class}: #{e.message}"
        end
      end
    end

    def jid_of(work)
      JSON.parse(work.raw_job)['jid']
    rescue StandardError
      '?'
    end

    def execute(work)
      job = parse_job(work)
      return unless job

      register_in_workers(work.queue, job)
      Cogworker.logger.info { "start: #{job['class']} jid=#{job['jid']}" }

      begin
        # `build_worker` itself can raise (most commonly `NameError`, e.g. a
        # class the caller registered/enqueued but never actually defined —
        # deliberately still routed through the *same* middleware chain
        # below rather than caught here directly: `History::Middleware`/
        # `Status::ServerMiddleware` (and any custom server middleware)
        # only ever see a job by wrapping this `chain.invoke` call, so a
        # resolution failure caught out here, before `invoke` ever runs,
        # would never reach them — this job would fail/retry/die with no
        # History entry and no status update at all, silently. Catching it
        # here and re-raising it as the chain's own "final block" gives
        # every middleware the same crack at observing this failure as any
        # perform-time one, with `worker` as `nil` in that case (every
        # built-in server middleware ignores the `worker` arg entirely
        # already; a custom one that needs a real instance simply can't act
        # on this failure either way — there's no worker to act on).
        resolution_error = nil
        worker = begin
          build_worker(job)
        rescue Exception => e # rubocop:disable Lint/RescueException
          resolution_error = e
          nil
        end

        Cogworker.config.server_chain.invoke(worker, job, work.queue) do
          raise resolution_error if resolution_error

          worker.perform(*job['args'])
        end
        Cogworker.config.redis { |c| c.incr(RedisKeys::STATS_PROCESSED) }
        Throughput.record('processed')
        Cogworker.logger.info { "done: #{job['class']} jid=#{job['jid']}" }
      rescue Exception => e # rubocop:disable Lint/RescueException
        Cogworker.config.redis { |c| c.incr(RedisKeys::STATS_FAILED) }
        Throughput.record('failed')
        route_failure(job, e)
        Cogworker.logger.warn { "fail: #{job['class']} jid=#{job['jid']}: #{e.class}: #{e&.message}" }
      end
    ensure
      deregister_from_workers
    end

    # A payload that isn't a JSON object goes straight to `dead`
    # (`JobUtil.unparseable_job`), and `nil` tells `execute` to skip it.
    # Before this, `JSON.parse` raised outside any rescue: the job was lost
    # and the processor thread died with it.
    def parse_job(work)
      job = JSON.parse(work.raw_job)
      raise JSON::ParserError, "expected a JSON object, got #{job.class}" unless job.is_a?(Hash)

      job
    rescue JSON::ParserError => e
      bury_unparseable(work, e)
      nil
    end

    def bury_unparseable(work, error)
      job = JobUtil.unparseable_job(work.raw_job, queue: work.queue, error: error)
      Cogworker.config.redis do |c|
        c.zadd(RedisKeys::DEAD, job['failed_at'], JSON.generate(job))
        c.incr(RedisKeys::STATS_FAILED)
      end
      Throughput.record('failed')
      Cogworker.logger.error { "unparseable job on queue #{work.queue} moved to dead: #{error.message}" }
    end

    # Built on first use, not in the constructor (see Manager#fetch_class),
    # and rebuilt after a fall-back to BasicFetch.
    def fetcher
      @fetcher ||= @manager.fetch_class.new(@manager.queues)
    end

    def build_worker(job)
      klass = Object.const_get(job['class'])
      worker = klass.new
      worker.jid = job['jid'] if worker.respond_to?(:jid=)
      worker
    end

    def route_failure(job, error)
      job['error_class'] = error.class.name
      job['error_message'] = error.message.to_s[0, 10_000]
      job['failed_at'] ||= Time.now.to_f

      max_retries = JobUtil.max_retries(job)
      new_count = job['retry_count'].to_i + 1
      job['retry_count'] = new_count

      if new_count <= max_retries
        delay = retry_delay(new_count)
        Cogworker.config.redis { |c| c.zadd(RedisKeys::RETRY, Time.now.to_f + delay, JSON.generate(job)) }
        extend_locks_for_retry(job, delay)
        Attempts.record(job['jid'], attempt: new_count, error: error, outcome: 'retrying')
      else
        Cogworker.config.redis { |c| c.zadd(RedisKeys::DEAD, Time.now.to_f, JSON.generate(job)) }
        Attempts.record(job['jid'], attempt: new_count, error: error, outcome: 'dead')
      end
    end

    # A job waiting out its retry backoff still holds its `until_executed`
    # lock(s) — extended here to cover that whole wait plus the usual
    # `unique_lock_ttl`, since a fixed TTL counted from the original push
    # ran out during a long retry series (the delay grows as `count**4`)
    # and let a duplicate in. Owner-checked, so a lock that has since
    # passed to another jid is left alone.
    def extend_locks_for_retry(job, delay)
      ttl = delay + Cogworker.config.unique_lock_ttl
      Cogworker.config.redis do |c|
        if UniqueJobs.until_executed?(job)
          OwnedKey.expire(RedisKeys.unique_lock(UniqueJobs.digest(job)), job['jid'], ttl, c)
        end
        Periodic::RunningLock.touch(job['periodic_pjid'], job['jid'], ttl, c) if job['periodic_pjid']
      end
    end

    # Grows with the retry count, with jitter to avoid a thundering herd of
    # retries all landing on the same second.
    def retry_delay(count)
      (count**4) + 15 + (rand(30) * (count + 1))
    end

    def register_in_workers(queue, job)
      payload = JSON.generate('queue' => queue, 'payload' => job, 'run_at' => Time.now.to_i)
      Cogworker.config.redis { |c| c.hset(RedisKeys.workers(Cogworker.identity), tid, payload) }
    end

    def deregister_from_workers
      Cogworker.config.redis { |c| c.hdel(RedisKeys.workers(Cogworker.identity), tid) }
    end
  end
end
