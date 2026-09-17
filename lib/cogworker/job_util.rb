# frozen_string_literal: true

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
  end
end
