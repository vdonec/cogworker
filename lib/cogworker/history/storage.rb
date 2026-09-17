# frozen_string_literal: true

require 'json'

module Cogworker
  module History
    # Three parallel ZSETs (score = finished_at), so any of the three
    # filters (all/success/failed) is a plain `ZREVRANGE` — no per-request
    # `ZUNIONSTORE`/scan needed. Each is trimmed to `History.max_entries`
    # independently on every write, oldest first.
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
        max = Cogworker::History.max_entries
        Cogworker.config.redis do |c|
          write_and_trim(c, LIST_KEYS.fetch('all'), raw, finished_at, max)
          write_and_trim(c, LIST_KEYS.fetch(status), raw, finished_at, max)
        end
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

      def write_and_trim(conn, key, raw, score, max)
        conn.zadd(key, score, raw)
        conn.zremrangebyrank(key, 0, -(max + 1))
      end

      # Success/failed counts per UTC calendar day, for the last `days` days
      # (today included) — `{ 'YYYY-MM-DD' => { 'success' => n, 'failed' => n } }`,
      # a day with no entries simply absent from the Hash. Reads the shared
      # "all" list once (rather than "success" and "failed" separately) since
      # every entry already carries its own `status`. Bucketing uses UTC,
      # not the viewer's browser timezone (unlike `Layout.time_tag`
      # elsewhere) — this is a server-rendered daily aggregate, not a single
      # instant, so there's no one "browser day" to convert into.
      # Same caveat as any other read of this list: only entries still
      # within `History.max_entries` are counted, so a very busy queue's
      # oldest requested days may already have been trimmed away.
      def daily_counts(days)
        since = Time.now.to_f - (days * 86_400)
        Cogworker.config.redis do |c|
          c.zrangebyscore(LIST_KEYS.fetch('all'), since, '+inf').each_with_object({}) do |raw, counts|
            entry = JSON.parse(raw)
            day = Time.at(entry['finished_at']).utc.strftime('%Y-%m-%d')
            bucket = (counts[day] ||= { 'success' => 0, 'failed' => 0 })
            bucket[entry['status']] += 1 if bucket.key?(entry['status'])
          end
        end
      end
    end
  end
end
