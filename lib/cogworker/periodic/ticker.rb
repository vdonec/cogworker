# frozen_string_literal: true

require 'fugit'
require 'json'

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

      def initialize(manager, entries, catch_up: true)
        @manager = manager
        @entries = entries
        @catch_up = catch_up
        @last_checked_slot = {}
        @cron_cache = {}
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

      def run
        until @manager.stopping?
          tick unless @manager.quiet?
          sleep(TICK_INTERVAL)
        end
      rescue StandardError => e
        Cogworker.logger.error { "Periodic ticker died: #{e.class}: #{e.message}" }
      end

      def tick
        now = Time.now
        @entries.each do |entry|
          slot = cron_for(entry).previous_time(now).to_i
          next if @last_checked_slot[entry.pjid] == slot

          enqueue(entry, slot) if claim?(entry, slot)
          @last_checked_slot[entry.pjid] = slot
        end
      end

      def cron_for(entry)
        @cron_cache[entry.pjid] ||= Fugit::Cron.parse(entry.cron)
      end

      def claim?(entry, slot)
        return false if !@catch_up && priming_first_slot?(entry, slot)

        result = Cogworker.config.redis do |c|
          c.eval(CLAIM_SCRIPT,
                 keys: [RedisKeys.periodic_running(entry.pjid), RedisKeys.periodic_last_slot(entry.pjid),
                        RedisKeys.periodic_lock(entry.pjid, slot)],
                 argv: [slot, entry.unique.to_s, LOCK_TTL])
        end
        result == 1
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

      def enqueue(entry, slot)
        job = {
          'class' => entry.class_name, 'args' => entry.args, 'retry' => entry.retry,
          'periodic_pjid' => entry.pjid, 'periodic_slot' => slot
        }
        jid = Client.push(job)
        return unless entry.until_executed?

        Cogworker.config.redis { |c| c.set(RedisKeys.periodic_running(entry.pjid), jid) }
      end
    end
  end
end
