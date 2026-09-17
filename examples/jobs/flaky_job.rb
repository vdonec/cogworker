# frozen_string_literal: true

# Demonstrates:
# - `cogworker_options` with a limited retry count and a custom key
#   (`lock_run`) that isn't part of the standard option set — it just rides
#   along in the job hash for any middleware that cares to read it.
# - `Cogworker::Status::Worker`, so this job's progress is queryable via
#   `Cogworker::Status.status(jid)` (queued -> working -> retrying -> failed,
#   or complete once it succeeds).
class FlakyJob
  include Cogworker::Worker
  include Cogworker::Status::Worker

  cogworker_options retry: 2, lock_run: :while_executing

  def perform(fail_times)
    attempts_key = "examples:flaky_job:#{jid}:attempts"
    attempt = Cogworker.config.redis { |c| c.incr(attempts_key) }
    at((attempt.to_f / (fail_times.to_i + 1) * 100).round, "attempt #{attempt}")

    raise "simulated failure (attempt #{attempt} of #{fail_times})" if attempt <= fail_times.to_i

    Cogworker.logger.info { "FlakyJob succeeded on attempt #{attempt}" }
  end
end
