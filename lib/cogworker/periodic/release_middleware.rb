# frozen_string_literal: true

module Cogworker
  module Periodic
    # Drives the server side of the `periodic:running:<pjid>` lock (used
    # only for `unique: :until_executed` entries; see RunningLock for the
    # whole lifecycle): shortens it to `RunningLock.active_ttl` when the run
    # starts, and releases it on success or on the terminal failed attempt
    # (a failure that will be retried is `Processor#route_failure`'s to
    # extend — only it knows the retry delay).
    # A no-op for any job that isn't periodic-scheduled (`job['periodic_pjid']`
    # absent) — and every call is a no-op on a lock owned by another jid, so
    # it's harmless for a non-`until_executed` entry too. Registered
    # unconditionally in every Config, not gated on whether
    # `config.periodic` is actually used, so it never becomes a hidden
    # dependency of the (separate) job status layer.
    class ReleaseMiddleware
      def call(_worker, job, _queue)
        pjid = job['periodic_pjid']
        return yield unless pjid

        shorten_lock(pjid, job['jid'])
        begin
          yield
        rescue Exception => e # rubocop:disable Lint/RescueException
          release(pjid, job['jid']) if JobUtil.terminal_failure?(job)
          raise e
        end
        release(pjid, job['jid'])
      end

      private

      # Best-effort — a release that fails (Redis away) never turns the
      # finished run into a failure — and retried later (DeferredReleases)
      # rather than left to the lock's TTL.
      def release(pjid, jid)
        released = BestEffort.call('Periodic lock') do
          RunningLock.release(pjid, jid)
          true
        end
        DeferredReleases.add(RedisKeys.periodic_running(pjid), jid) unless released
      end

      # Best-effort: failing here must not stop the job from running (it
      # would be routed to retry/dead as if it had failed). If it does fail,
      # the lock just keeps its longer queued TTL until this process's next
      # heartbeat shortens it — within Heartbeat::INTERVAL.
      def shorten_lock(pjid, jid)
        RunningLock.touch(pjid, jid, RunningLock.active_ttl)
      rescue StandardError => e
        Cogworker.logger.warn { "couldn't shorten periodic lock for #{pjid}: #{e.class}: #{e.message}" }
      end
    end
  end
end
