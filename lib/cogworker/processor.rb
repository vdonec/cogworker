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
          RedisErrors.recovered('Processor') unless process_one == :idle
        rescue StandardError => e
          RedisErrors.report('Processor', e)
          sleep(ERROR_BACKOFF)
        end
      end
    end

    def process_one
      if @manager.quiet?
        sleep(0.5)
        return :idle # (no Redis call made)
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
      @performed = false
      @decision = nil
      @death = nil
      disposition = nil
      begin
        disposition = execute(work)
      ensure
        @busy = false
        @manager.job_performed(work.raw_job) unless @performed
        @manager.processor_idle!
        # `execute` raising leaves `disposition` unset: before the job ran
        # that's a hand-back; once it ran, whatever its outcome dictates
        # (`@ran`, set the moment `run_job` returns) — so an unexpected
        # exception later in the bookkeeping (a bug, a misbehaving logger)
        # can't re-queue a job that already ran.
        settle(work, disposition || @ran || :give_back)
        @manager.job_finished(work.raw_job)
        # Only now, with the job acknowledged (or its ack remembered): a
        # slow hook used to hold it on the in-progress list, where a
        # shutdown or orphan recovery requeued it and ran it again.
        DeathNotifier.notify(*@death) if @death
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
      # No retries left (`retry: false`/`0`, or the last one used up, or the
      # job's `cogworker_retry_in` ended it) means no extra attempt either —
      # straight to dead, like any terminal failure.
      out_of_retries = attempt > JobUtil.max_retries(payload) || @decision&.cut_short?
      delay = INTERRUPT_DELAY * count
      set, score = if out_of_retries || count > MAX_INTERRUPTS
                     [RedisKeys::DEAD, Time.now.to_f]
                   else
                     [RedisKeys::RETRY, Time.now.to_f + delay]
                   end
      encoded = JSON.generate(payload)
      begin
        written = fetcher.interrupt(work, set, score, encoded) != 0 # (0: no longer ours to file)
      rescue StandardError
        # Remembered with its payload: this process's reconcile (and its
        # shutdown) keep trying to file it — never re-run it as a stray.
        @manager.settle_later(work.raw_job, [set, score, encoded]) if fetcher.is_a?(ReliableFetch)
        raise
      end
      after_interrupt(job, payload, error, set, delay, written)
      reason = interrupt_reason(set, out_of_retries, count, delay)
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

    def after_interrupt(job, payload, error, set, delay, written)
      if set == RedisKeys::RETRY
        best_effort('lock extension') { extend_locks_for_retry(job, delay) }
      else
        best_effort('lock release') { release_locks(payload) }
        @death = [payload, error] if written # run by `process_one`, once settled
      end
    end

    def interrupt_reason(set, out_of_retries, count, delay)
      return "retrying in #{delay}s (interruption #{count} of at most #{MAX_INTERRUPTS})" if set == RedisKeys::RETRY

      out_of_retries ? 'moved to dead: no retries left' : "moved to dead: interrupted more than #{MAX_INTERRUPTS} times"
    end

    def remember_for_dead(work, error)
      # The original job's own fields where readable (so filing it releases
      # its locks); just enough to show in Dead otherwise.
      base = ReliableFetch.parse_hash(work.raw_job) || { 'raw_payload' => JobUtil.safe_string(work.raw_job, 100_000) }
      entry = JSON.generate(base.merge('jid' => jid_of(work), 'error_class' => error.class.name.to_s,
                                       'error_message' => JobUtil.error_message(error), 'failed_at' => Time.now.to_f))
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
        @manager.job_performed(work.raw_job)
        @performed = true
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

      @job_class = worker&.class
      Cogworker.config.server_chain.invoke(worker, job, work.queue) do
        raise resolution_error if resolution_error

        begin
          worker.perform(*job['args'])
        rescue Exception => e # rubocop:disable Lint/RescueException
          # Retry, dead or discard — decided here, while the middleware is
          # still to see the failure (FailureDecision.decide!).
          @decision = FailureDecision.decide!(job, e, @job_class)
          raise
        end
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
      Cogworker.logger.warn do
        "fail: #{job['class']} jid=#{job['jid']}: #{error.class}: #{JobUtil.error_message(error)}"
      end
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
      @decided_late = @decision.nil? # raised by middleware, not `perform`: decided after the chain
      @decision ||= FailureDecision.decide!(job, error, @job_class)
      decision = @decision || FailureDecision.new(JobUtil.terminal_failure?(job) ? 'dead' : 'retry')
      job.delete('failure_outcome')
      job['error_class'] = error.class.name
      job['error_message'] = JobUtil.error_message(error)
      job['failed_at'] ||= Time.now.to_f
      new_count = job['retry_count'].to_i + 1
      job['retry_count'] = new_count
      if decision.discard? # neither retry nor dead, no death hooks: the job just ends, counted as failed
        after_failure_recorded(job, error, decision, nil)
        return true
      end

      delay = decision.delay || retry_delay(new_count) if decision.retry?
      begin
        payload = JSON.generate(job)
        Cogworker.config.redis do |c|
          if decision.retry?
            c.zadd(RedisKeys::RETRY, Time.now.to_f + delay, payload)
          else
            c.zadd(RedisKeys::DEAD, Time.now.to_f, payload)
          end
        end
      rescue StandardError => e
        Cogworker.logger.error { "couldn't record failure of jid=#{job['jid']}: #{e.class}: #{e.message}" }
        return false
      end

      after_failure_recorded(job, error, decision, delay)
      @death = [JSON.parse(payload), error] if decision.dead? # run by `process_one`, once settled
      true
    end

    def after_failure_recorded(job, error, decision, delay)
      if decision.retry?
        best_effort('lock extension') { extend_locks_for_retry(job, delay) }
      elsif decision.cut_short?
        # Normally the release middleware's, on the terminal attempt — but
        # a decision made after the chain (a middleware raised) never
        # reached it. Owner-checked, so releasing twice is harmless. Same
        # for the status the Status middleware wrote then: 'retrying'.
        best_effort('lock release') { release_locks(job) }
        best_effort('status') { Status.mark_failed(job, error) } if @decided_late
      end
      best_effort('attempts log') do
        Attempts.record(job['jid'], attempt: job['retry_count'], error: error, outcome: decision.attempt_outcome)
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

    # Into dead by way of `interrupt` — possibly with retries still left,
    # so the middleware that normally releases a terminal failure's locks
    # didn't: release them here (owner-checked).
    def release_locks(job)
      Cogworker.config.redis { |c| JobUtil.release_terminal_locks(c, job) }
    end

    # The default backoff, for a job whose class has no say in it.
    def retry_delay(count)
      FailureDecision.default_delay(count)
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
