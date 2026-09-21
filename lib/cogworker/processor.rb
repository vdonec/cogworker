# frozen_string_literal: true

require 'json'
require 'securerandom'

module Cogworker
  # One thread of a Manager's pool: fetch -> register in-flight -> run the
  # server middleware chain around perform -> stats/retry -> deregister.
  class Processor
    attr_reader :thread, :tid

    def initialize(manager)
      @manager = manager
      @tid = SecureRandom.hex(6)
      @fetcher = BasicFetch.new(manager.queues)
    end

    def start!
      @thread = Thread.new { run }
    end

    private

    def run
      until @manager.stopping?
        if @manager.quiet?
          sleep(0.5)
          next
        end

        work = @fetcher.retrieve_work
        next unless work

        @manager.processor_busy!
        begin
          execute(work)
        ensure
          @manager.processor_idle!
        end
      end
    rescue StandardError => e
      Cogworker.logger.error { "Processor thread died: #{e.class}: #{e.message}" }
    end

    def execute(work)
      job = JSON.parse(work.raw_job)
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
        Attempts.record(job['jid'], attempt: new_count, error: error, outcome: 'retrying')
      else
        Cogworker.config.redis { |c| c.zadd(RedisKeys::DEAD, Time.now.to_f, JSON.generate(job)) }
        Attempts.record(job['jid'], attempt: new_count, error: error, outcome: 'dead')
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
