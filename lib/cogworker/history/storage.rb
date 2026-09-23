# frozen_string_literal: true

require 'json'

module Cogworker
  module History
    # Three parallel ZSETs (score = finished_at), so any of the three
    # filters (all/success/failed) is a plain `ZREVRANGE` — no per-request
    # `ZUNIONSTORE`/scan needed. Each is trimmed independently on every
    # write, oldest first, by age (`History.retention_days`, the primary,
    # expected limit) and then by count (`History.max_entries`, a safety
    # ceiling only — see both constants' own comments in `history.rb`) —
    # see `write_and_trim`. Alongside those, `record` also maintains one
    # small per-UTC-day Hash counter (`daily_counts` reads these back) —
    # kept deliberately separate from, and unaffected by, either trim above
    # (see `daily_counts`' own comment).
    module Storage
      LIST_KEYS = {
        'all' => 'cogworker:history:all',
        'success' => 'cogworker:history:success',
        'failed' => 'cogworker:history:failed'
      }.freeze

      module_function

      def record(job, queue, started_at, finished_at, status, error: nil)
        entry = {
          'jid' => job['jid'], 'class' => job['class'], 'queue' => queue, 'args' => job['args'],
          'status' => status, 'started_at' => started_at, 'finished_at' => finished_at
        }
        if error
          entry['error_class'] = error.class.name
          entry['error_message'] = error.message.to_s[0, 10_000]
          entry['backtrace'] = (error.backtrace || []).first(200)
        end

        raw = JSON.generate(entry)
        Cogworker.config.redis do |c|
          write_and_trim(c, LIST_KEYS.fetch('all'), raw, finished_at)
          write_and_trim(c, LIST_KEYS.fetch(status), raw, finished_at)
          # Independent of the two trims above — see `daily_counts`' own
          # comment for why "Runs per day" can't just read the `all` list.
          bump_daily_count(c, finished_at, status)
        end
      end

      def bump_daily_count(conn, finished_at, status)
        daily_key = RedisKeys.history_daily_bucket(Time.at(finished_at).utc.strftime('%Y-%m-%d'))
        conn.hincrby(daily_key, status, 1)
        conn.expire(daily_key, Cogworker::History.daily_stats_retention_days * 86_400)
      end

      # Newest-first page of `count`/`status` entries: `[entries, total]`.
      def page(status, page_number, per_page)
        key = LIST_KEYS.fetch(status, LIST_KEYS.fetch('all'))
        start = [(page_number - 1), 0].max * per_page
        stop = start + per_page - 1

        Cogworker.config.redis do |c|
          total = c.zcard(key)
          raw_entries = c.zrevrange(key, start, stop)
          [raw_entries.map { |raw| JSON.parse(raw) }, total]
        end
      end

      def write_and_trim(conn, key, raw, score)
        conn.zadd(key, score, raw)
        # Age first — the primary, expected trim in normal operation: gone
        # once older than `History.retention_days`, regardless of how few
        # entries that leaves. Count second, as a safety ceiling only — see
        # `History::DEFAULT_MAX_ENTRIES`'s own comment for why both run on
        # every write rather than just one. Both read fresh from
        # `Cogworker::History` here (rather than being passed in) so a
        # config change takes effect on the very next write, same as
        # `max_entries` always has.
        cutoff = Time.now.to_f - (Cogworker::History.retention_days * 86_400)
        conn.zremrangebyscore(key, '-inf', cutoff)
        conn.zremrangebyrank(key, 0, -(Cogworker::History.max_entries + 1))
      end

      # Success/failed counts per UTC calendar day, for the last `days` days
      # (today included) — `{ 'YYYY-MM-DD' => { 'success' => n, 'failed' => n } }`,
      # a day with no entries simply absent from the Hash. Bucketing uses
      # UTC, not the viewer's browser timezone (unlike `Layout.time_tag`
      # elsewhere) — this is a server-rendered daily aggregate, not a single
      # instant, so there's no one "browser day" to convert into.
      #
      # Reads `RedisKeys.history_daily_bucket(day)` (one small Hash per day,
      # `record` above keeps them updated) rather than scanning the `all`
      # list and bucketing entries by hand — deliberately: even now that the
      # `all`/`success`/`failed` lists are trimmed by age (`History.
      # retention_days`) rather than purely by count, that's still a
      # *different*, independently configured window than the daily
      # buckets' own (`History.daily_stats_retention_days`, TTL-based, same
      # idea as `Cogworker::Throughput`'s hourly buckets) — a "6 months"
      # chart request would find nothing if it depended on `all` still
      # holding 6 months of entries, since `retention_days` defaults to
      # far less than that. The daily buckets are sized (and meant) to
      # outlive the raw per-entry lists, so "Runs per day" stays accurate
      # regardless of how short `retention_days` is configured.
      def daily_counts(days)
        now = Time.now.utc
        day_strings = (days - 1).downto(0).map { |offset| (now - (offset * 86_400)).strftime('%Y-%m-%d') }
        raw = Cogworker.config.redis { |c| c.pipelined { |pipe| day_strings.each { |d| daily_hmget(pipe, d) } } }
        day_strings.zip(raw).each_with_object({}) do |(day, (success, failed)), counts|
          next if success.nil? && failed.nil?

          counts[day] = { 'success' => success.to_i, 'failed' => failed.to_i }
        end
      end

      def daily_hmget(pipe, day)
        pipe.hmget(RedisKeys.history_daily_bucket(day), 'success', 'failed')
      end
    end
  end
end
