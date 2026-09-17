# frozen_string_literal: true

require 'json'

module Cogworker
  # Enqueues jobs: normalizes the job hash, runs the client middleware
  # chain, then pushes onto the target queue or schedule ZSET.
  class Client
    class << self
      # Cogworker::Client.push(hash) — the single funnel every enqueue path
      # (perform_async/perform_in/perform_at, and direct calls) goes through.
      def push(item)
        job = JobUtil.normalize_item(item)
        queue = job['queue']

        Cogworker.config.client_chain.invoke(job['class'], job, queue, Cogworker.config.redis_pool) do
          dispatch(job)
        end

        # UniqueJobs::ClientMiddleware sets this when the job was a
        # duplicate of an already-enqueued/running `unique: :until_executed`
        # job and never actually reached `dispatch` — nil signals "nothing
        # was pushed", same as `job['jid']` would be meaningless otherwise.
        job['unique_skipped'] ? nil : job['jid']
      end

      def push_bulk(items)
        items.map { |item| push(item) }
      end

      private

      # Testing.fake?/.inline? divert the enqueue entirely; both still ran
      # the client middleware chain above them in #push, same as the real
      # push would.
      def dispatch(job)
        if Testing.fake?
          Testing.jobs_for(job['class']) << job
        elsif Testing.inline?
          Testing.perform_inline(job)
        else
          raw_push(job)
        end
      end

      def raw_push(job)
        Cogworker.config.redis do |conn|
          if job['at']
            conn.zadd(RedisKeys::SCHEDULE, job['at'].to_f, JSON.generate(job))
          else
            job['enqueued_at'] = Time.now.to_f
            conn.multi do |pipeline|
              pipeline.sadd(RedisKeys::QUEUES, job['queue'])
              pipeline.lpush(RedisKeys.queue(job['queue']), JSON.generate(job))
            end
          end
        end
      end
    end
  end
end
