# frozen_string_literal: true

module Cogworker
  # Per-hour processed/failed counters, feeding Overview's own "Throughput"
  # chart (the "Relay" concept mock's own sparkline — dropped in the
  # initial nocturne migration for lack of real data; this is that data).
  # Distinct from `Cogworker::Stats`' plain running totals (`cogworker:
  # stats:processed`/`:failed`, incremented forever, no time dimension) and
  # from `Cogworker::History` (a capped log of individual runs, one entry
  # per job) — this is neither a total nor a per-job record, just how many
  # finished in each one-hour bucket, bounded to the last `WINDOW_HOURS` by
  # each bucket's own TTL rather than any trim/cleanup pass.
  #
  # Hour buckets, not minute ones: the mock's own "24h" sparkline is 24
  # sample points (one per hour), not 1440 — matching that resolution
  # keeps `.series` a 24-key read (cheap enough to poll every few seconds)
  # instead of 1440.
  module Throughput
    WINDOW_HOURS = 24
    BUCKET_TTL = (WINDOW_HOURS + 1) * 3600 # a bit of slack past the window itself

    module_function

    def record(outcome, at: Time.now)
      key = RedisKeys.throughput_bucket(bucket_for(at))
      Cogworker.config.redis do |c|
        c.hincrby(key, outcome, 1)
        c.expire(key, BUCKET_TTL)
      end
    end

    # One entry per hour, oldest first, covering exactly the last `hours`
    # hours ending now — including hours with no activity at all (a real
    # "0 processed" reads as an honest gap, not a jump the chart papers
    # over by skipping it).
    def series(hours: WINDOW_HOURS, now: Time.now)
      end_bucket = bucket_for(now)
      buckets = ((end_bucket - hours + 1)..end_bucket).to_a
      raw = Cogworker.config.redis do |c|
        c.pipelined { |pipe| buckets.each { |b| pipe.hmget(RedisKeys.throughput_bucket(b), 'processed', 'failed') } }
      end
      buckets.zip(raw).map do |bucket, (processed, failed)|
        { 'time' => Time.at(bucket * 3600).utc, 'processed' => processed.to_i, 'failed' => failed.to_i }
      end
    end

    def bucket_for(time)
      time.to_i / 3600
    end
  end
end
