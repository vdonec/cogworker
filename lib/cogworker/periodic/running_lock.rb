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
    # - shortened to `active_ttl` once a processor starts it, then kept alive
    #   by that process's Heartbeat every beat — so a run whose process dies
    #   (OOM, SIGKILL, shutdown past the drain timeout) can't hold the entry
    #   forever. `active_ttl` deliberately outlives the time it takes for
    #   that dead process's job to be recovered (`config.orphan_threshold`
    #   plus one orphan check), so the lock is still there, still owned by
    #   that job, when the job is requeued — at which point `retake` (or ReliableFetch's
    #   REQUEUE_SCRIPT) extends it again for the wait in the queue. A shorter
    #   TTL let the lock lapse first: the ticker would enqueue the next slot
    #   while the recovered run was still to come, i.e. two runs at once.
    # - extended on a non-terminal failure to cover the retry backoff plus
    #   `queued_ttl` (`Processor#extend_locks_for_retry` — the job now waits
    #   in `cogworker:retry`, not on a process).
    # - deleted on success or on the terminal failure.
    module RunningLock
      # Lua, prepended to every script that puts a job back on its queue
      # (ReliableFetch::REQUEUE_SCRIPT, BasicFetch::REQUEUE_ENTRY_SCRIPT), so
      # the requeue and the lock move together in one atomic step. Extends
      # the lock if still that job's, takes it if it lapsed, leaves it if a
      # newer run holds it.
      RETAKE_FUNCTION = <<~LUA
        local function retake_running_lock(lock, jid, ttl)
          local owner = redis.call("GET", lock)
          if not owner then
            redis.call("SET", lock, jid, "EX", ttl)
          elseif owner == jid then
            redis.call("EXPIRE", lock, ttl)
          end
        end
      LUA

      module_function

      # Whole seconds: it goes straight into `SET ... EX` in claim.lua, which
      # rejects a non-integer (a fractional `unique_lock_ttl` used to make
      # every claim — and so every tick — fail).
      # A method, not a constant: it follows `config.orphan_threshold`.
      def active_ttl
        (Cogworker.config.orphan_threshold + Scheduled::ORPHAN_CHECK_INTERVAL + 60).to_f.ceil
      end

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
