# frozen_string_literal: true

require 'fugit'
require 'json'
require 'securerandom'

module Cogworker
  module Periodic
    # One per process, started from the same post-fork boot path as
    # Heartbeat/Scheduled (never before a swarm fork). Every TICK_INTERVAL,
    # for each registered entry, computes the most recent cron slot and — if
    # this process hasn't already handled that exact slot — attempts the
    # atomic Lua claim; only the winner enqueues the job.
    class Ticker
      TICK_INTERVAL = 5
      LOCK_TTL = TICK_INTERVAL * 4

      CLAIM_SCRIPT = File.read(File.join(__dir__, 'claim.lua'))

      # Undoes a won claim whose push then failed, so the slot isn't lost:
      # puts `last_slot` back (only if it still is this slot — a later slot
      # may have been claimed since) and drops the per-slot NX lock.
      # KEYS[1] = last_slot, KEYS[2] = slot lock; ARGV[1] = slot, ARGV[2] =
      # previous last_slot ("" if none: then slot - 1, which still lets this
      # slot fire, unlike deleting the key — with catch_up off, a missing
      # last_slot would be re-primed to this very slot instead).
      ROLLBACK_SCRIPT = <<~LUA
        if redis.call("GET", KEYS[1]) == ARGV[1] then
          if ARGV[2] == "" then
            redis.call("SET", KEYS[1], tostring(tonumber(ARGV[1]) - 1))
          else
            redis.call("SET", KEYS[1], ARGV[2])
          end
        end
        redis.call("DEL", KEYS[2])
        return 1
      LUA

      def initialize(manager, entries, catch_up: true, ready: -> { true })
        @manager = manager
        @entries = entries
        @catch_up = catch_up
        @ready = ready
        @last_checked_slot = {}
        @cron_cache = {}
        @pending_rollbacks = []
      end

      def start!
        publish_schedule!
        @thread = Thread.new { run }
      end

      # See Scheduled#stop! for why this kills outright rather than joining:
      # same non-daemon-thread-blocks-process-exit hazard, same up-to-5s
      # (TICK_INTERVAL) sleep it would otherwise have to wake from first.
      def stop!
        @thread&.kill
      end

      private

      # Persisted for restart survival and Web UI visibility. Written from
      # here (not at DSL-registration time in Config#periodic) so it never
      # depends on `config.redis =` having already run — every process that
      # boots re-writes the same idempotent entries regardless of ordering.
      def publish_schedule!
        return if @entries.empty?

        payloads = @entries.each_with_object({}) do |entry, h|
          h[entry.pjid] = JSON.generate(
            'cron' => entry.cron, 'class' => entry.class_name, 'retry' => entry.retry,
            'unique' => entry.unique, 'args' => entry.args
          )
        end
        Cogworker.config.redis { |c| c.hset(RedisKeys::PERIODIC_SCHEDULE, *payloads.to_a.flatten) }
      end

      # A failed tick is logged and retried next interval rather than ending
      # the thread — a single Redis blip used to silently stop every
      # periodic entry in this process for good. A slot whose claim or push
      # raised isn't recorded in `@last_checked_slot` (and a failed push
      # rolls its claim back — see #enqueue), so the next tick retries it.
      def run
        until @manager.stopping?
          begin
            tick unless @manager.quiet? || !@ready.call
          rescue StandardError => e
            Cogworker.logger.error { "Periodic tick failed: #{e.class}: #{e.message}" }
          end
          sleep(TICK_INTERVAL)
        end
      end

      def tick
        retry_pending_rollbacks
        now = Time.now
        @entries.each do |entry|
          slot = cron_for(entry).previous_time(now).to_i
          next if @last_checked_slot[entry.pjid] == slot

          jid = SecureRandom.hex(12)
          previous = claim(entry, slot, jid) unless disabled?(entry)
          enqueue(entry, slot, jid, previous) if previous
          @last_checked_slot[entry.pjid] = slot
        end
      end

      # Web UI "Disable" (`Routes::Schedules`) — skips the claim/enqueue
      # step entirely, short-circuiting before `claim` even runs, so
      # neither `periodic:last_slot:<pjid>` nor the per-slot lock advance
      # while disabled: the Web UI's own "LastRun" column keeps showing the
      # last time it *actually* ran, not a due-but-skipped slot, and
      # re-enabling doesn't trigger a catch-up burst for every slot that
      # was silently skipped in between. `@last_checked_slot` (this one
      # Ticker instance's own in-memory dedup, unrelated to the Redis-
      # persisted last_slot) still advances either way, exactly as it
      # already did before this entry ever had a disabled state — it only
      # stops this same tick loop from re-evaluating the same slot twice.
      # The usual reason a push fails — Redis unreachable — makes this fail
      # too; it's then kept and retried at the start of every tick until it
      # goes through (before that tick looks at the slot again), rather than
      # just logged and the slot lost. (A push that timed out *after* Redis
      # had applied it is the one case this turns into a second run of the
      # slot: indistinguishable from one that never arrived.)
      def rollback_claim(entry, slot, previous_slot)
        Cogworker.config.redis do |c|
          keys = [RedisKeys.periodic_last_slot(entry.pjid), RedisKeys.periodic_lock(entry.pjid, slot)]
          LuaScript.run(c, ROLLBACK_SCRIPT, keys: keys, argv: [slot, previous_slot])
        end
        true
      rescue StandardError => e
        Cogworker.logger.error { "periodic #{entry.pjid}: couldn't roll back slot #{slot} (will retry): #{e.class}: #{e.message}" }
        @pending_rollbacks << [entry, slot, previous_slot]
        false
      end

      def retry_pending_rollbacks
        pending = @pending_rollbacks
        @pending_rollbacks = []
        pending.each { |args| rollback_claim(*args) }
      end

      def disabled?(entry)
        Cogworker.config.redis { |c| c.sismember(RedisKeys::PERIODIC_DISABLED, entry.pjid) }
      end

      def cron_for(entry)
        @cron_cache[entry.pjid] ||= Fugit::Cron.parse(entry.cron)
      end

      # nil if this process didn't win the slot; otherwise the previous
      # `last_slot` value ("" if none), for #rollback_claim.
      def claim(entry, slot, jid)
        return nil if !@catch_up && priming_first_slot?(entry, slot)

        result = Cogworker.config.redis do |c|
          LuaScript.run(c, CLAIM_SCRIPT,
                 keys: [RedisKeys.periodic_running(entry.pjid), RedisKeys.periodic_last_slot(entry.pjid),
                        RedisKeys.periodic_lock(entry.pjid, slot)],
                 argv: [slot, entry.unique.to_s, LOCK_TTL, jid, RunningLock.queued_ttl])
        end
        result.is_a?(Array) ? result[1].to_s : nil
      end

      # With catch-up disabled, an entry's very first tick — ever, across
      # every process, since `periodic:last_slot:<pjid>` doesn't exist yet —
      # must not fire the most-recently-due slot: that's exactly what makes
      # every registered entry fire at once on a cold start against an
      # empty/reset Redis (fresh deploy, Redis loss/restore). SETNX-ing the
      # slot as the baseline (instead of enqueueing) fixes that without
      # touching the claim script: it's a genuine "first tick" only when the
      # key doesn't already exist, so racing sibling processes at boot agree
      # on one winner (the rest see NX fail and skip too, same as any other
      # tick), and an ordinary restart — where `last_slot` already persists
      # from a prior run — falls through to the real claim below unchanged,
      # still firing at most one catch-up run for whatever slot is due.
      def priming_first_slot?(entry, slot)
        return false unless @last_checked_slot[entry.pjid].nil?

        Cogworker.config.redis { |c| c.set(RedisKeys.periodic_last_slot(entry.pjid), slot, nx: true) }
      end

      # The running lock (for `until_executed`) is already in place, set by
      # the claim under this same `jid` — nothing to write after the push.
      # That relies on the job keeping that jid: `JobUtil.normalize_item`
      # only fills `jid` in when absent, but a custom client middleware that
      # overwrites it would leave the lock owned by a jid no job carries —
      # the entry then stays closed for `RunningLock.queued_ttl` (logged).
      # Only undone here if the push didn't actually produce a job (raised,
      # or a client middleware swallowed it), so a job that never existed
      # can't hold the entry for the whole `RunningLock.queued_ttl`.
      def enqueue(entry, slot, jid, previous_slot)
        job = {
          'class' => entry.class_name, 'args' => entry.args, 'retry' => entry.retry,
          'periodic_pjid' => entry.pjid, 'periodic_slot' => slot, 'jid' => jid
        }
        # Lets a requeue after a crash/shutdown re-take this run's lock
        # (Periodic::RunningLock::RETAKE_FUNCTION, in both fetches' requeue scripts).
        job['periodic_until_executed'] = true if entry.until_executed?
        pushed = begin
          Client.push(job)
        rescue StandardError
          RunningLock.release(entry.pjid, jid) if entry.until_executed?
          rollback_claim(entry, slot, previous_slot)
          raise
        end
        return unless entry.until_executed?

        if pushed.nil?
          RunningLock.release(entry.pjid, jid)
        elsif pushed != jid
          Cogworker.logger.warn do
            "periodic #{entry.pjid}: a client middleware changed the job's jid (#{jid} -> #{pushed}); its running " \
              "lock won't be released by the job and keeps the entry closed for up to #{RunningLock.queued_ttl}s"
          end
        end
      end
    end
  end
end
