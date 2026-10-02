# frozen_string_literal: true

require 'json'
require 'securerandom'

module Cogworker
  # One thread of a Manager's pool: fetch -> register in-flight -> run the
  # server middleware chain around perform -> stats/retry -> deregister.
  #
  # What happens to the fetched job afterwards depends on how far it got —
  # the one rule being that a job is never re-run because of a failure that
  # happened *after* it ran:
  # - failed before `perform` (registering it in `cogworker:workers`):
  #   `give_back` — straight back on its queue, it hasn't run yet;
  # - ran (succeeded, or failed and was recorded in retry/dead): acknowledge.
  #   Everything after `perform` other than that one retry/dead write —
  #   stats, throughput, deregistering, lock extension, the attempts log —
  #   is best-effort: logged, never raised;
  # - ran and failed, but the retry/dead write itself failed: `interrupt` —
  #   into `retry` after INTERRUPT_DELAY, counting `interrupted_count`, and
  #   into `dead` once that passes MAX_INTERRUPTS. Never straight back on
  #   the queue: a write that fails deterministically used to make that
  #   loop forever, re-running the job every second.
  class Processor
    ERROR_BACKOFF = 1 # seconds
    ACK_ATTEMPTS = 3
    MAX_INTERRUPTS = 3
    INTERRUPT_DELAY = 30 # seconds, times the interruption count

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
      @manager.job_started(work.raw_job)
      @busy = true
      @ran = nil
      disposition = nil
      begin
        disposition = execute(work)
      ensure
        @busy = false
        @manager.processor_idle!
        # `execute` raising leaves `disposition` unset: before the job ran
        # that's a hand-back; once it ran, whatever its outcome dictates
        # (`@ran`, set the moment `run_job` returns) — so an unexpected
        # exception later in the bookkeeping (a bug, a misbehaving logger)
        # can't re-queue a job that already ran.
        settle(work, disposition || @ran || :give_back)
        @manager.job_finished(work.raw_job)
      end
    end

    def settle(work, disposition)
      case disposition
      when :acknowledge then acknowledge(work)
      when :give_back then give_back(work)
      else interrupt(work, *disposition.drop(1))
      end
    end

    # Only for a job that hasn't run yet (see the class comment). If even
    # this fails, it stays on the in-progress list, which `Manager#stop!` /
    # orphan recovery / `ReliableFetch.reconcile` requeue later.
    def give_back(work)
      fetcher.give_back(work)
    rescue StandardError => e
      Cogworker.logger.error do
        "couldn't hand back jid=#{jid_of(work)} (left in progress): #{e.class}: #{e.message}"
      end
    end

    # The job ran and failed, but recording that in retry/dead failed. Built
    # from the original payload (always serializable — it came from JSON)
    # plus the failure fields, never from the in-memory job hash: whatever
    # made that one fail to serialize must not do it again here.
    def interrupt(work, job, error)
      payload = JSON.parse(work.raw_job)
      count = payload['interrupted_count'].to_i + 1
      # This attempt's number, from the payload as fetched — not from the
      # in-memory job, whose count `route_failure` may not have got to.
      attempt = payload['retry_count'].to_i + 1
      payload.merge!('interrupted_count' => count, 'retry_count' => attempt,
                     'error_class' => error.class.name, 'error_message' => JobUtil.error_message(error),
                     'failed_at' => Time.now.to_f)
      # No retries left (`retry: false`/`0`, or the last one used up) means
      # no extra attempt either — straight to dead, like any terminal failure.
      out_of_retries = attempt > JobUtil.max_retries(payload)
      delay = INTERRUPT_DELAY * count
      set, score = if out_of_retries || count > MAX_INTERRUPTS
                     [RedisKeys::DEAD, Time.now.to_f]
                   else
                     [RedisKeys::RETRY, Time.now.to_f + delay]
                   end
      encoded = JSON.generate(payload)
      begin
        fetcher.interrupt(work, set, score, encoded)
      rescue StandardError
        # Remembered with its payload: this process's reconcile (and its
        # shutdown) keep trying to file it — never re-run it as a stray.
        @manager.settle_later(work.raw_job, [set, score, encoded]) if fetcher.is_a?(ReliableFetch)
        raise
      end
      best_effort('lock extension') { extend_locks_for_retry(job, delay) } if set == RedisKeys::RETRY
      reason = if set == RedisKeys::RETRY
                 "retrying in #{delay}s (interruption #{count} of at most #{MAX_INTERRUPTS})"
               elsif out_of_retries
                 'moved to dead: no retries left'
               else
                 "moved to dead: interrupted more than #{MAX_INTERRUPTS} times"
               end
      Cogworker.logger.error { "couldn't record the failure of jid=#{payload['jid']} (#{error.class}); #{reason}" }
    rescue StandardError => e
      # Whatever failed (even before anything was written), remember the job
      # with the simplest possible dead entry, so reconcile files it — not
      # leave it a stray to be re-run. (Already remembered if it got as far
      # as the write.)
      remember_for_dead(work, error) if fetcher.is_a?(ReliableFetch) && !@manager.pending_settlements.key?(work.raw_job)
      Cogworker.logger.error do
        "couldn't record or interrupt jid=#{jid_of(work)} (left in progress): #{e.class}: #{e.message}"
      end
    end

    def remember_for_dead(work, error)
      entry = JSON.generate('jid' => jid_of(work), 'error_class' => error.class.name.to_s,
                            'error_message' => JobUtil.error_message(error), 'failed_at' => Time.now.to_f,
                            'raw_payload' => JobUtil.safe_string(work.raw_job, 100_000))
      @manager.settle_later(work.raw_job, [RedisKeys::DEAD, Time.now.to_f, entry])
    rescue StandardError
      nil
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
        # Remembered, so this process's own reconcile finishes the ack later
        # instead of mistaking the entry for a stray and re-running it.
        @manager.settle_later(work.raw_job, :ack)
        Cogworker.logger.error do
          "couldn't acknowledge finished job jid=#{jid_of(work)} after #{attempts} attempts " \
            "(will retry; it may run again if this process stops first): #{e.class}: #{e.message}"
        end
      end
    end

    def jid_of(work)
      JSON.parse(work.raw_job)['jid']
    rescue StandardError
      '?'
    end

    # Returns how `settle` should dispose of the fetched job. If it raises
    # instead, `process_one` falls back on `@ran` — set the moment the job
    # has run — or, before that, on :give_back.
    def execute(work)
      job = parse_job(work)
      return :acknowledge unless job

      # Best-effort: for the reliable fetch the in-progress list is what
      # keeps the job safe; `cogworker:workers` only feeds the Workers tab
      # (and BasicFetch's shutdown requeue). A failure here — even a
      # deterministic one, the key holding the wrong type — used to hand
      # the job back before it ever ran, over and over.
      best_effort('register') { register_in_workers(work.queue, job) }
      Cogworker.logger.info { "start: #{job['class']} jid=#{job['jid']}" }
      begin
        error = run_job(work, job)
        @ran = error ? [:interrupt, job, error] : :acknowledge
        error ? finish_failure(job, error) : finish_success(job)
      ensure
        best_effort('deregister') { deregister_from_workers }
      end
    end

    # The job's own outcome: nil, or what it (or its middleware) raised.
    def run_job(work, job)
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
      nil
    rescue Exception => e # rubocop:disable Lint/RescueException
      e
    end

    def finish_success(job)
      best_effort('stats') do
        Cogworker.config.redis { |c| c.incr(RedisKeys::STATS_PROCESSED) }
        Throughput.record('processed')
      end
      Cogworker.logger.info { "done: #{job['class']} jid=#{job['jid']}" }
      :acknowledge
    end

    def finish_failure(job, error)
      best_effort('stats') do
        Cogworker.config.redis { |c| c.incr(RedisKeys::STATS_FAILED) }
        Throughput.record('failed')
      end
      Cogworker.logger.warn { "fail: #{job['class']} jid=#{job['jid']}: #{error.class}: #{JobUtil.error_message(error)}" }
      route_failure(job, error) ? :acknowledge : [:interrupt, job, error]
    end

    def best_effort(what)
      yield
    rescue StandardError => e
      Cogworker.logger.error { "#{what} failed (ignored): #{e.class}: #{e.message}" }
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
      @fetcher ||= @manager.fetch_class.new(@manager.queues, stopping: -> { @manager.stopping? })
    end

    def build_worker(job)
      klass = Object.const_get(job['class'])
      worker = klass.new
      worker.jid = job['jid'] if worker.respond_to?(:jid=)
      worker
    end

    # True once the failure is recorded in retry/dead — the one write that
    # must happen; everything after it is best-effort. False if that write
    # failed (`finish_failure` then interrupts the job instead).
    def route_failure(job, error)
      job['error_class'] = error.class.name
      job['error_message'] = JobUtil.error_message(error)
      job['failed_at'] ||= Time.now.to_f

      max_retries = JobUtil.max_retries(job)
      new_count = job['retry_count'].to_i + 1
      job['retry_count'] = new_count
      retrying = new_count <= max_retries
      delay = retry_delay(new_count) if retrying

      begin
        payload = JSON.generate(job)
        Cogworker.config.redis do |c|
          retrying ? c.zadd(RedisKeys::RETRY, Time.now.to_f + delay, payload) : c.zadd(RedisKeys::DEAD, Time.now.to_f, payload)
        end
      rescue StandardError => e
        Cogworker.logger.error { "couldn't record failure of jid=#{job['jid']}: #{e.class}: #{e.message}" }
        return false
      end

      best_effort('lock extension') { extend_locks_for_retry(job, delay) } if retrying
      best_effort('attempts log') do
        Attempts.record(job['jid'], attempt: new_count, error: error, outcome: retrying ? 'retrying' : 'dead')
      end
      true
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
