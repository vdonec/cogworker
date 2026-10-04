# frozen_string_literal: true

module Cogworker
  # Lock releases that failed (Redis away when a job finished) — kept here
  # and retried on every heartbeat beat (Heartbeat#beat) until they go
  # through, owner-checked like the original release. A failed release is
  # best-effort so it can't fail the job, but left alone it held the lock
  # until its TTL: an `until_executed` cron entry skipped slots for up to
  # `RunningLock.active_ttl`, a unique job blocked its duplicates for up to
  # `unique_lock_ttl`. In this process's memory only: one still pending when
  # the process exits falls back to the lock's TTL.
  module DeferredReleases
    @mutex = Mutex.new
    @pending = {} # lock key => owner jid

    class << self
      def add(key, owner)
        @mutex.synchronize { @pending[key] = owner }
      end

      # Retries every pending release; stops at the first one Redis can't
      # serve (no point hammering it), keeps whatever's left.
      def retry_all(conn)
        pending.each do |key, owner|
          OwnedKey.delete(key, owner, conn) # (a no-op if it lapsed or changed hands meanwhile)
          @mutex.synchronize { @pending.delete(key) if @pending[key] == owner }
        rescue StandardError => e
          raise if RedisErrors.unavailable?(e)

          # Anything else (the key holding the wrong type, say) won't get
          # better by retrying every 5s: dropped, logged once.
          @mutex.synchronize { @pending.delete(key) if @pending[key] == owner }
          Cogworker.logger.error { "deferred release of #{key} dropped: #{e.class}: #{e.message}" }
        end
      end

      def pending
        @mutex.synchronize { @pending.dup }
      end

      def reset!
        @mutex.synchronize { @pending.clear }
      end
    end
  end
end
