# frozen_string_literal: true

require 'json'

module Cogworker
  # Background poller: moves due jobs from the `cogworker:schedule` and
  # `cogworker:retry` ZSETs into their target queue. Safe with many processes
  # polling concurrently: `ZREM` returning 1 (vs 0) is the atomic "I won the
  # race to graduate this job" signal — the same pattern the periodic
  # scheduler's Lua claim later builds on for its own exactly-once guarantee.
  class Scheduled
    SETS = [RedisKeys::SCHEDULE, RedisKeys::RETRY].freeze
    POLL_INTERVAL = 5

    def initialize(manager)
      @manager = manager
    end

    def start!
      @thread = Thread.new { run }
    end

    # Killed outright, not gracefully joined: unlike a Processor (which may
    # be mid-job), this thread only ever holds the GVL briefly between one
    # POLL_INTERVAL sleep and the next, so there's nothing to drain. Without
    # this, the thread would only notice `@manager.stopping?` after waking
    # from its own up-to-5s sleep — and since it's a non-daemon thread, the
    # OS process can't actually exit until then, which a caller blocked on a
    # plain (no-timeout) `Process.waitpid` for this process — Swarm's
    # phased restart — would otherwise just sit stuck behind.
    def stop!
      @thread&.kill
    end

    private

    def run
      until @manager.stopping?
        enqueue_due_jobs unless @manager.quiet?
        sleep(POLL_INTERVAL)
      end
    rescue StandardError => e
      Cogworker.logger.error { "Scheduled poller died: #{e.class}: #{e.message}" }
    end

    def enqueue_due_jobs
      now = Time.now.to_f
      SETS.each do |set|
        candidates = Cogworker.config.redis { |c| c.zrangebyscore(set, '-inf', now, limit: [0, 50]) }
        candidates.each { |raw| graduate(set, raw) }
      end
    end

    def graduate(set, raw)
      Cogworker.config.redis do |c|
        won = c.zrem(set, raw)
        next unless won

        job = JSON.parse(raw)
        c.multi do |pipeline|
          pipeline.sadd(RedisKeys::QUEUES, job['queue'])
          pipeline.lpush(RedisKeys.queue(job['queue']), raw)
        end
      end
    end
  end
end
