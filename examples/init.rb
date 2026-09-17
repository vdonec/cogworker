# frozen_string_literal: true

# Example process init file — what you'd point `-r`/`--require` at, e.g.:
#
#   bundle exec exe/cogworker -r ./examples/init.rb -C ./examples/cogworker.yml
#
# This mirrors the shape of a real backend's own init file: connect to
# Redis, build the server/client middleware chains, register periodic jobs,
# and load the job classes. Nothing here is required by the gem itself —
# it's just one reasonable way to wire it up.

require 'cogworker'

Dir[File.join(__dir__, 'jobs', '*.rb')].sort.each { |f| require f }

# A tiny custom server middleware, to show the extension point real
# middleware (dedup, metrics, history, process-recycling) hooks into.
# Signature: `call(worker, job, queue, &block)`.
class TimingMiddleware
  def call(_worker, job, queue)
    start = Time.now
    yield
    Cogworker.logger.info { "#{job['class']}##{job['jid']} on #{queue} took #{(Time.now - start).round(3)}s" }
  end
end

Cogworker.configure_server do |config|
  config.redis = { url: ENV.fetch('COGWORKER_EXAMPLE_REDIS_URL', 'redis://localhost:6379/0') }

  config.server_middleware do |chain|
    chain.add(TimingMiddleware)
  end

  Cogworker::Status.configure_server_middleware(config, expiration: 1800)
  Cogworker::Status.configure_client_middleware(config, expiration: 1800)

  # Keep the last 500 runs (success and failure) per filter, browsable on
  # the Web UI's History tab with full args and, for failures, a backtrace.
  Cogworker::History.configure_server_middleware(config, max_entries: 500)

  config.periodic do |mgr|
    mgr.register '*/5 * * * *', 'DailyReportJob', retry: 0, unique: :until_executed,
                                                  args: [{ section: 'hourly_digest' }]
  end
end

Cogworker.configure_client do |config|
  config.redis = { url: ENV.fetch('COGWORKER_EXAMPLE_REDIS_URL', 'redis://localhost:6379/0') }
end
