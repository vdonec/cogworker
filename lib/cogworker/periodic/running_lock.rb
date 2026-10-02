# frozen_string_literal: true

module Cogworker
  module Periodic
    # `periodic:running:<pjid>` — the "an earlier run of this entry hasn't
    # finished yet" lock behind `unique: :until_executed` periodic entries.
    #
    # Lifecycle (every write keyed on the owning jid, so a stray older run
    # can never shorten, extend or release a newer run's lock):
    # - set by `claim.lua`, atomically with the slot claim itself, *before*
    #   the job is pushed — setting it after the push let a fast job finish
    #   (and release a lock that didn't exist yet) before the lock was
    #   written, wedging the entry forever. TTL = `queued_ttl`, covering
    #   however long the job may wait in its queue.
    # - shortened to ACTIVE_TTL once a processor starts it, then kept alive
    #   by that process's Heartbeat every beat — so a run whose process dies
    #   (OOM, SIGKILL, shutdown past the drain timeout) frees the entry
    #   within ACTIVE_TTL instead of never.
    # - extended on a non-terminal failure to cover the retry backoff plus
    #   `queued_ttl` (`Processor#extend_locks_for_retry` — the job now waits
    #   in `cogworker:retry`, not on a process).
    # - deleted on success or on the terminal failure.
    module RunningLock
      ACTIVE_TTL = 60

      module_function

      # Whole seconds: it goes straight into `SET ... EX` in claim.lua, which
      # rejects a non-integer (a fractional `unique_lock_ttl` used to make
      # every claim — and so every tick — fail).
      def queued_ttl
        Cogworker.config.unique_lock_ttl.to_f.ceil
      end

      def touch(pjid, jid, ttl, conn = nil)
        OwnedKey.expire(RedisKeys.periodic_running(pjid), jid, ttl, conn)
      end

      def release(pjid, jid, conn = nil)
        OwnedKey.delete(RedisKeys.periodic_running(pjid), jid, conn)
      end
    end
  end
end
