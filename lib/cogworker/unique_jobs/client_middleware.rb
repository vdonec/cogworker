# frozen_string_literal: true

module Cogworker
  module UniqueJobs
    # Client middleware, registered unconditionally on every `Config` (like
    # `Periodic::ReleaseMiddleware` on the server side) — a no-op for any
    # job that isn't `unique: :until_executed`. For one that is, atomically
    # claims `cogworker:unique:<digest>` (`SET NX`) before letting the job
    # continue down the chain to the real push. A job that loses the claim
    # (another copy is already enqueued/scheduled/running) never reaches
    # `dispatch` at all — it sets `job['unique_skipped']` instead, which
    # `Client.push` reads to return `nil` rather than a jid, the same
    # "nothing was actually pushed" signal `sidekiq-unique-jobs` gives.
    class ClientMiddleware
      def call(_worker_class, job, _queue, redis_pool = Cogworker.config.redis_pool)
        return yield unless UniqueJobs.until_executed?(job)

        acquired = redis_pool.with do |c|
          c.set(RedisKeys.unique_lock(UniqueJobs.digest(job)), job['jid'],
                nx: true, ex: Cogworker.config.unique_lock_ttl)
        end

        if acquired
          yield
        else
          job['unique_skipped'] = true
        end
      end
    end
  end
end
