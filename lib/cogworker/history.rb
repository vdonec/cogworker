# frozen_string_literal: true

module Cogworker
  # Execution history: every job run (success and failure alike) is recorded
  # with its full args, timing, and — on failure — error class/message/
  # backtrace. Distinct from the Status layer (`Cogworker::Status`), which
  # tracks *current* per-jid state with a TTL; History is an append-only log
  # meant for browsing/auditing past runs, trimmed by age first.
  module History
    # The primary, expected trim for the "all"/"success"/"failed" lists —
    # anything older than this many days is gone on the next write,
    # regardless of how few (or many) entries that leaves. See `Storage.
    # write_and_trim`.
    DEFAULT_RETENTION_DAYS = 30
    # A safety ceiling, not the everyday trim mechanism — `retention_days`
    # above is. Each entry in the lists it bounds carries its full args and,
    # on failure, up to 200 backtrace lines, so a burst of traffic under a
    # purely time-based trim could otherwise grow Redis memory unboundedly
    # until those entries finally age out; this caps that. Sized well above
    # what `retention_days`' default window is expected to hold in normal
    # operation specifically so it stays a rare safety net rather than the
    # thing actually doing the trimming day to day — if it's the one
    # regularly cutting entries short of `retention_days`, raise it (or
    # lower `retention_days`) to match this queue's real volume.
    DEFAULT_MAX_ENTRIES = 50_000
    # "Runs per day" (`Storage.daily_counts`) reads a separate, per-UTC-day
    # counter (`RedisKeys.history_daily_bucket`) rather than the capped
    # `all`/`success`/`failed` lists above, specifically so those lists'
    # own trim (age- or count-based) doesn't also blow away the daily
    # chart's older days — see `Storage`'s own comment. Each day's counter
    # self-expires via `EXPIRE`, the same TTL-based cleanup `Cogworker::
    # Throughput` already uses for its hourly buckets, rather than a
    # count-based trim: 400 days comfortably covers the widest period the
    # built-in chart offers (6 months / 182 days) with real margin, so a
    # viewer opening that period on day 1 of a new retention window still
    # sees its oldest days.
    DEFAULT_DAILY_STATS_RETENTION_DAYS = 400

    class << self
      # How many days an entry survives in the "all"/"success"/"failed"
      # lists before `write_and_trim` removes it — read fresh on every
      # write, so changing it takes effect immediately, no need to rebuild
      # the middleware chain. Configurable via
      # `configure_server_middleware(config, retention_days: N)`, or
      # directly: `Cogworker::History.retention_days = 90`.
      attr_writer :retention_days
      # The count-based safety ceiling alongside `retention_days` above —
      # see `DEFAULT_MAX_ENTRIES`. Configurable via
      # `configure_server_middleware(config, max_entries: N)`, or directly:
      # `Cogworker::History.max_entries = 50_000`.
      attr_writer :max_entries
      # How many days a "Runs per day" daily counter survives before
      # self-expiring — independent of `retention_days`/`max_entries` above
      # (see `DEFAULT_DAILY_STATS_RETENTION_DAYS`). Configurable via
      # `configure_server_middleware(config, daily_stats_retention_days: N)`,
      # or directly: `Cogworker::History.daily_stats_retention_days = 800`.
      attr_writer :daily_stats_retention_days

      def retention_days
        @retention_days ||= DEFAULT_RETENTION_DAYS
      end

      def max_entries
        @max_entries ||= DEFAULT_MAX_ENTRIES
      end

      def daily_stats_retention_days
        @daily_stats_retention_days ||= DEFAULT_DAILY_STATS_RETENTION_DAYS
      end
    end

    module_function

    def configure_server_middleware(config, retention_days: DEFAULT_RETENTION_DAYS,
                                    max_entries: DEFAULT_MAX_ENTRIES,
                                    daily_stats_retention_days: DEFAULT_DAILY_STATS_RETENTION_DAYS)
      self.retention_days = retention_days
      self.max_entries = max_entries
      self.daily_stats_retention_days = daily_stats_retention_days
      config.server_middleware { |chain| chain.add(Middleware) }
    end
  end
end
