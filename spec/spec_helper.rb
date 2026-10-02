# frozen_string_literal: true

require 'cogworker'
require 'json'

TEST_REDIS_URL = ENV.fetch('COGWORKER_TEST_REDIS_URL', 'redis://localhost:6379/15')

def wait_for(timeout: 5)
  deadline = Time.now + timeout
  loop do
    result = yield
    return result if result

    raise "timed out after #{timeout}s waiting for condition" if Time.now > deadline

    sleep 0.05
  end
end

# A queue's jobs as parsed Hashes, minus the `enqueued_at` every requeue
# (`JobUtil.claim_and_requeue`) re-stamps — for asserting "this job is back on its
# queue" without depending on the exact moment it got there.
def queued_jobs(queue = 'default')
  Cogworker.config.redis { |c| c.lrange("cogworker:queue:#{queue}", 0, -1) }
           .map { |raw| JSON.parse(raw).except('enqueued_at') }
end

RSpec.configure do |config|
  config.expect_with(:rspec) { |c| c.syntax = :expect }

  config.before do
    Cogworker.instance_variable_set(:@config, nil)
    Cogworker.instance_variable_set(:@server_process, nil)
    Cogworker.config.redis = { url: TEST_REDIS_URL }
    Cogworker.config.redis(&:flushdb)
    Cogworker::Testing.disable!
    Cogworker::Testing.clear_jobs!
  end

  # `:reliable_fetch` examples need LMOVE (Redis >= 6.2); `:old_redis` ones
  # only make sense without it (CI also runs the suite against Redis 6.0).
  # Declared after the hook above, so they ask the test Redis, not a default.
  config.before(:each, :reliable_fetch) do
    skip 'needs Redis >= 6.2 (LMOVE)' unless Cogworker::ReliableFetch.supported?
  end
  config.before(:each, :old_redis) do
    skip 'only meaningful on Redis < 6.2' if Cogworker::ReliableFetch.supported?
  end
end
