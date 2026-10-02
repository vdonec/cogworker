# frozen_string_literal: true

require 'json'
require 'securerandom'

module Cogworker
  # Shared job-hash helpers: normalizing a client-supplied item, and the one
  # correct `retry:`/`retry_count` accounting used by every caller that needs
  # to know how many attempts a job gets or whether a failure is terminal.
  module JobUtil
    DEFAULT_MAX_RETRY_ATTEMPTS = 25

    module_function

    # Normalizes a client-supplied job item (symbol or string keys mixed) into
    # the canonical string-keyed job hash used everywhere from here on: client
    # middleware, storage in Redis, server middleware, and the introspection
    # API. Custom `cogworker_options` keys (e.g. `lock_run`) are preserved
    # verbatim — normalization never allowlist-filters keys.
    def normalize_item(item)
      job = item.each_with_object({}) { |(k, v), h| h[k.to_s] = v }

      job['class'] = job['class'].to_s if job['class'].respond_to?(:to_s) && !job['class'].is_a?(String)
      job['jid'] ||= SecureRandom.hex(12)
      job['queue'] ||= 'default'
      job['args'] ||= []
      job['retry'] = true unless job.key?('retry')
      job['created_at'] ||= Time.now.to_f
      job
    end

    # How many total attempts a job gets, per its `retry:`/`cogworker_options
    # retry:` value: `false` -> none, `true`/absent -> the default cap, an
    # integer -> that many. `job['retry']` round-trips through JSON, so this
    # sees the literal `false`/`true`/Integer/nil, never a String — do NOT
    # simplify this to `job['retry'].to_i`: `FalseClass`/`NilClass` don't
    # define `#to_i` (`nil.to_i` happens to be `0` — coincidentally correct
    # for absent — but `false.to_i` raises `NoMethodError` outright, which is
    # exactly the bug this method exists to not have).
    def max_retries(job)
      case job['retry']
      when false then 0
      when true, nil then DEFAULT_MAX_RETRY_ATTEMPTS
      else job['retry'].to_i
      end
    end

    # Whether `job['retry_count']` (attempts already made, *before* this
    # failure) has already reached this job's retry budget — i.e. this
    # failed attempt is the last one it gets, whether or not `Processor` has
    # incremented `retry_count` for it yet. Shared by every place that needs
    # to know if a failure is final: `Processor#route_failure` (routes to
    # retry vs dead), `Status::ServerMiddleware` ('failed' vs 'retrying'),
    # `Periodic::ReleaseMiddleware` (releases the running-lock only on the
    # terminal attempt) — previously three separate, subtly different copies
    # of this same check, two of which had the `max_retries` bug above.
    def terminal_failure?(job)
      job['retry_count'].to_i >= max_retries(job)
    end

    # The job Hash a raw `schedule`/`retry`/`dead` entry would requeue as —
    # or `nil` if it can't be: not JSON, not an object, or no String
    # `queue` to push it onto (e.g. an `unparseable_job` wrapper, whose
    # `queue` may be nil).
    def requeueable(raw)
      job = JSON.parse(raw)
      job.is_a?(Hash) && job['queue'].is_a?(String) && !job['queue'].empty? ? job : nil
    rescue JSON::ParserError, TypeError
      nil
    end

    # KEYS[1] = the ZSET, KEYS[2] = cogworker:queues, KEYS[3] = the queue;
    # ARGV[1] = the entry as stored, ARGV[2] = queue name, ARGV[3] = the
    # payload to push. Claim and push in one atomic step: as separate
    # commands, a crash or dropped connection between the ZREM and the
    # LPUSH lost the job. The new payload is built in Ruby, not re-encoded
    # by Lua's cjson (which would round large integers in args).
    CLAIM_AND_REQUEUE_SCRIPT = <<~LUA
      if redis.call("ZREM", KEYS[1], ARGV[1]) == 0 then
        return 0
      end
      redis.call("SADD", KEYS[2], ARGV[2])
      redis.call("LPUSH", KEYS[3], ARGV[3])
      return 1
    LUA

    # Validate, then (atomically) claim and requeue — an entry that can't be
    # requeued is never removed and lost (it stays where it is for the
    # caller to deal with). Returns `:requeued`, `:gone` (someone else
    # claimed it first) or `:invalid`. The one implementation behind
    # `Scheduled#graduate` and every Web UI retry action. Re-stamps
    # `enqueued_at`: queue latency is measured from it, and a retried job
    # still carried its original push time (a scheduled one, none at all).
    def claim_and_requeue(conn, set, raw)
      job = requeueable(raw)
      return :invalid unless job

      job['enqueued_at'] = Time.now.to_f
      won = conn.eval(CLAIM_AND_REQUEUE_SCRIPT,
                      keys: [set, RedisKeys::QUEUES, RedisKeys.queue(job['queue'])],
                      argv: [raw, job['queue'], JSON.generate(job)])
      won == 1 ? :requeued : :gone
    end

    UNPARSEABLE_CLASS = '(unparseable)'

    # A payload that isn't a JSON object can't be run, retried or even
    # attributed to a class. Wrapped into a regular job Hash (the Web UI
    # parses every Dead entry as one) that keeps the original bytes under
    # `raw_payload`, for whoever finds one to bury it in `dead`.
    def unparseable_job(raw, queue:, error:)
      now = Time.now.to_f
      {
        'class' => UNPARSEABLE_CLASS, 'args' => [], 'queue' => queue, 'jid' => SecureRandom.hex(12),
        'retry' => false, 'retry_count' => 0, 'enqueued_at' => now, 'failed_at' => now,
        'error_class' => error.class.name, 'error_message' => error.message.to_s[0, 10_000],
        'raw_payload' => raw.to_s[0, 100_000]
      }
    end
  end
end
