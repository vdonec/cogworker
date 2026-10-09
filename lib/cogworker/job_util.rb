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
    #
    # Anything else (a Hash, a non-numeric String…) means no retries — the
    # cautious reading for a job with side effects — rather than raising
    # from the middle of recording its failure.
    def max_retries(job)
      case (value = job['retry'])
      when false then 0
      when true, nil then DEFAULT_MAX_RETRY_ATTEMPTS
      when Integer then value
      when Float then value.to_i
      when String then Integer(value, exception: false) || 0
      else 0
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
    #
    # A job class's `cogworker_retry_in` can end a job early (`:kill`,
    # `:discard`): `Processor` stamps that decision on the job as
    # `failure_outcome` (FailureDecision) before the middleware sees the
    # failure, and it wins here when present.
    def terminal_failure?(job)
      outcome = job['failure_outcome']
      return outcome != 'retry' if FailureDecision::OUTCOMES.include?(outcome)

      job['retry_count'].to_i >= max_retries(job)
    end

    # A copy of a job hash to hand to user code, so changes it makes can't
    # leak back. Never raises: unlike a JSON round trip, it copes with
    # whatever middleware may have put in the hash (the job being on its
    # way to `interrupt` precisely because that doesn't serialize).
    def deep_copy(value)
      case value
      when Hash then value.to_h { |k, v| [deep_copy(k), deep_copy(v)] }
      when Array then value.map { |v| deep_copy(v) }
      when String then value.dup
      else value
      end
    end

    # Calls a user-supplied hook (a block, lambda, Method or any `#call`
    # object) with as many of `args` as it takes: a block with fewer
    # parameters ignores the rest anyway, a lambda or method would raise.
    # Counted from `parameters` (required + optional), not `arity`, which
    # is negative as soon as there's an optional one.
    def call_hook(hook, *args)
      callable = hook.is_a?(Proc) || hook.is_a?(Method) ? hook : hook.method(:call)
      return hook.call(*args) if callable.is_a?(Proc) && !callable.lambda?

      params = callable.parameters
      return hook.call(*args) if params.any? { |type, _| type == :rest }

      hook.call(*args.first(params.count { |type, _| %i[req opt].include?(type) }))
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
    # Present? Push, then remove — never remove first: a script stopped by
    # an error keeps the writes made before it, so a ZREM followed by a
    # failing LPUSH (the queue key holding the wrong type) lost the entry.
    # The `cogworker:queues` listing is best-effort.
    CLAIM_AND_REQUEUE_SCRIPT = <<~LUA
      if not redis.call("ZSCORE", KEYS[1], ARGV[1]) then
        return 0
      end
      redis.call("LPUSH", KEYS[3], ARGV[3])
      redis.call("ZREM", KEYS[1], ARGV[1])
      redis.pcall("SADD", KEYS[2], ARGV[2])
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
      won = LuaScript.run(conn, CLAIM_AND_REQUEUE_SCRIPT,
                          keys: [set, RedisKeys::QUEUES, RedisKeys.queue(job['queue'])],
                          argv: [raw, job['queue'], JSON.generate(job)])
      won == 1 ? :requeued : :gone
    end

    ERROR_MESSAGE_LIMIT = 10_000

    # Valid UTF-8, whatever came in — every string this gem stores from
    # outside its control (an exception's message, a raw payload) goes
    # through here before `JSON.generate`, which raises on invalid UTF-8.
    # An unchecked `raise "bad \xff".b` used to make every attempt to record
    # the failure itself raise, deterministically. Strings in another
    # (valid) encoding are transcoded; binary/broken ones are scrubbed.
    def safe_string(value, limit = nil)
      str = value.to_s
      str = if [Encoding::UTF_8, Encoding::BINARY, Encoding::US_ASCII].include?(str.encoding)
              str.dup.force_encoding(Encoding::UTF_8).scrub
            else
              str.encode(Encoding::UTF_8, invalid: :replace, undef: :replace)
            end
      limit ? str[0, limit] : str
    end

    # Never raises: an exception whose own `#message` raises (a broken
    # custom exception class) used to escape from the middle of recording
    # its failure — and, the job then counting as not-yet-run, it was handed
    # back and re-run about once a second, forever.
    def error_message(error)
      safe_string(error.message, ERROR_MESSAGE_LIMIT)
    rescue Exception # rubocop:disable Lint/RescueException
      "#<#{error.class}>"
    end

    # A job on its way to dead outside the usual path (no server middleware
    # around it to do this): releases its `until_executed` locks, owner-
    # checked, each on its own — so the entry / the unique key isn't blocked
    # until the locks' TTL. Best-effort.
    def release_terminal_locks(conn, job)
      keys = []
      keys << RedisKeys.unique_lock(UniqueJobs.digest(job)) if UniqueJobs.until_executed?(job)
      keys << RedisKeys.periodic_running(job['periodic_pjid']) if job['periodic_pjid']
      keys.each do |key|
        released = BestEffort.call('Lock release') do
          OwnedKey.delete(key, job['jid'], conn)
          true
        end
        DeferredReleases.add(key, job['jid']) unless released
      end
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
        'error_class' => error.class.name, 'error_message' => error_message(error),
        'raw_payload' => safe_string(raw, 100_000)
      }
    end
  end
end
