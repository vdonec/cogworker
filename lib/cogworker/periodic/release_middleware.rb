# frozen_string_literal: true

module Cogworker
  module Periodic
    # Releases the `periodic:running:<pjid>` lock (used only for
    # `unique: :until_executed` entries) on success, or on the terminal
    # failed attempt. A no-op for any job that isn't periodic-scheduled
    # (`job['periodic_pjid']` absent). Registered unconditionally in every
    # Config, not gated on whether `config.periodic` is actually used, so it
    # never becomes a hidden dependency of the (separate) job status layer.
    class ReleaseMiddleware
      def call(_worker, job, _queue)
        yield
        release(job) if job['periodic_pjid']
      rescue Exception => e # rubocop:disable Lint/RescueException
        release(job) if job['periodic_pjid'] && JobUtil.terminal_failure?(job)
        raise e
      end

      private

      def release(job)
        Cogworker.config.redis { |c| c.del(RedisKeys.periodic_running(job['periodic_pjid'])) }
      end
    end
  end
end
