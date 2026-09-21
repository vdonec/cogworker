# frozen_string_literal: true

require 'json'

module Cogworker
  # Per-job append-only log of failed attempts (attempt number, when, error
  # class/message, and whether that failure routed the job to retry or to
  # dead) — what `Processor#route_failure` appends to on every failure, and
  # what the Web UI's Jobs tab reads to render a retry timeline in a job's
  # detail panel.
  #
  # Distinct from `Cogworker::History`: History is every *completed* run
  # (success or failure) across every job, capped and trimmed independently
  # of any one job's fate. This is the *in-progress* failure trail for one
  # still-retrying-or-dead job, keyed by JID, growing one entry per attempt
  # until that job is deleted from Retries/Dead (`.clear`) or the key
  # expires on its own (`TTL_SECONDS`) if nothing ever does.
  module Attempts
    MAX_ENTRIES = 25
    TTL_SECONDS = 30 * 24 * 60 * 60 # 30 days — bounds an abandoned dead entry's log even if nothing ever calls `.clear`

    module_function

    def record(jid, attempt:, error:, outcome:)
      entry = JSON.generate(
        'attempt' => attempt, 'failed_at' => Time.now.to_f, 'outcome' => outcome,
        'error_class' => error.class.name, 'error_message' => error.message.to_s[0, 10_000]
      )
      key = RedisKeys.job_attempts(jid)
      Cogworker.config.redis do |c|
        c.rpush(key, entry)
        c.ltrim(key, -MAX_ENTRIES, -1)
        c.expire(key, TTL_SECONDS)
      end
    end

    # Oldest attempt first — the order a timeline reads top-to-bottom.
    def for(jid)
      raw = Cogworker.config.redis { |c| c.lrange(RedisKeys.job_attempts(jid), 0, -1) }
      raw.map { |r| JSON.parse(r) }
    end

    def clear(jid)
      Cogworker.config.redis { |c| c.del(RedisKeys.job_attempts(jid)) }
    end
  end
end
