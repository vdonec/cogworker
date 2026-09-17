# frozen_string_literal: true

require 'digest/sha1'
require 'json'

module Cogworker
  # Shared helpers for `unique: :until_executed` on regular jobs (anything
  # pushed through `Client.push` — `perform_async`/`perform_in`/
  # `perform_at`). Distinct from `Periodic::Entry#until_executed?`, which
  # locks one cron *slot* per pjid; this locks on job *content* instead, so
  # `ClientMiddleware` (before push) and `ReleaseMiddleware` (after the job
  # hash has round-tripped through Redis/JSON) always agree on the same key
  # without needing to stash it on the job hash itself.
  module UniqueJobs
    module_function

    # `job['unique']` round-trips through JSON exactly like `job['retry']`
    # (see `JobUtil.max_retries`) — a caller's `cogworker_options unique:
    # :until_executed`/direct push hash may still hold the Symbol at the
    # point `ClientMiddleware` sees it (before the job is ever
    # `JSON.generate`d), while `ReleaseMiddleware` only ever sees the
    # String a popped job was parsed back from. Comparing against `.to_s`
    # handles both, plus the absent (`nil`) case, uniformly.
    def until_executed?(job)
      job['unique'].to_s == 'until_executed'
    end

    def digest(job)
      Digest::SHA1.hexdigest("#{job['class']}|#{job['queue']}|#{job['args'].to_json}")
    end
  end
end
