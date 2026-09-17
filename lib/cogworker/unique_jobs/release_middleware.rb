# frozen_string_literal: true

module Cogworker
  module UniqueJobs
    # Releases the `cogworker:unique:<digest>` lock (claimed by
    # `ClientMiddleware` for `unique: :until_executed` jobs) on success, or
    # on the terminal failed attempt — mirrors `Periodic::ReleaseMiddleware`
    # exactly, just keyed by job content (class+queue+args) instead of a
    # periodic pjid, so a retried job keeps its lock (no duplicate can sneak
    # in while it's still retrying) and only releases once it's genuinely
    # done, one way or the other. A no-op for any job that isn't
    # `unique: :until_executed`. Registered unconditionally in every
    # `Config`, same as `Periodic::ReleaseMiddleware`.
    class ReleaseMiddleware
      def call(_worker, job, _queue)
        yield
        release(job) if UniqueJobs.until_executed?(job)
      rescue Exception => e # rubocop:disable Lint/RescueException
        release(job) if UniqueJobs.until_executed?(job) && JobUtil.terminal_failure?(job)
        raise e
      end

      private

      def release(job)
        Cogworker.config.redis { |c| c.del(RedisKeys.unique_lock(UniqueJobs.digest(job))) }
      end
    end
  end
end
