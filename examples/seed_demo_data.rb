# frozen_string_literal: true

# Populates the example Redis db with a realistic dataset spanning every Web
# UI tab, so you can just browse http://localhost:9394/cogworker and see
# something everywhere — instead of choreographing a live worker run just
# right to catch it mid-job. Safe to re-run (each run adds more history
# rather than erroring); flush the db yourself first if you want a clean
# slate:
#
#   redis-cli -n 0 flushdb   # or whatever COGWORKER_EXAMPLE_REDIS_URL points at
#   bundle exec ruby ./examples/seed_demo_data.rb

require_relative 'init'
require 'securerandom'
require 'digest/sha1'

# ---- Queues: real jobs actually waiting to be picked up — two different
#      queues (`default` and `low`, both listed in cogworker.yml), so the
#      Overview tab shows more than a single one right away ----
5.times { |i| GreetingJob.perform_async("queued visitor #{i}") }
3.times { |i| LowPriorityJob.perform_async("background task #{i}") } # queue: 'low'

# ---- Scheduled: a spread of future run times, real jobs a live worker
#      really would pick up later ----
GreetingJob.perform_in(30, 'in 30s')
GreetingJob.perform_in(300, 'in 5 min')
GreetingJob.perform_in(3600, 'in 1h')
FlakyJob.perform_in(1800, 1)

# ---- Periodic: registered cron schedules. Seeded directly (like Busy/Dead
#      below) rather than via `config.periodic` in init.rb, since that block
#      only runs in an actual server process (`Cogworker.server?`) — this
#      script isn't one, so the real DSL registration never fires here.
#      `periodic:schedule`/`periodic:last_slot:<pjid>` are exactly what
#      `Periodic::Ticker#publish_schedule!`/`#tick` write from a real
#      worker; the Web UI only ever reads them back. ----
periodic_entries = [
  ['*/5 * * * *', 'DailyReportJob', [{ 'section' => 'hourly_digest' }], 'until_executed', 240],
  ['0 * * * *', 'SyncInventoryJob', [], nil, 1500],
  ['0 3 * * *', 'PurgeOldSessionsJob', [], 'until_executed', nil] # never run yet
]
Cogworker.config.redis do |c|
  periodic_entries.each do |cron, klass, args, unique, last_slot_age|
    pjid = Digest::SHA1.hexdigest("#{cron}|#{klass}|#{args.to_json}")
    c.hset('periodic:schedule', pjid, JSON.generate('cron' => cron, 'class' => klass, 'retry' => 0,
                                                    'unique' => unique, 'args' => args))
    c.set("periodic:last_slot:#{pjid}", Time.now.to_i - last_slot_age) if last_slot_age
  end
end

# ---- Workers: a couple of processes that look like they're mid-job (no real
#      process behind them — just enough state for ProcessSet/WorkSet to
#      render something without needing a worker running *right now*) ----
fake_identities = Array.new(2) { |i| "demo-host:#{1234 + i}:#{SecureRandom.hex(6)}" }
Cogworker.config.redis do |c|
  fake_identities.each_with_index do |identity, i|
    info = { 'hostname' => 'demo-host', 'pid' => 1234 + i, 'concurrency' => 5,
             'queues' => %w[default low], 'started_at' => Time.now.to_f - 3600,
             'rss_kb' => 90_000 + (i * 15_000) }
    c.sadd('cogworker:processes', identity)
    c.hset("cogworker:process:#{identity}", 'info', JSON.generate(info), 'busy', '1', 'quiet', 'false')
    c.expire("cogworker:process:#{identity}", 600)

    job = { 'jid' => SecureRandom.hex(12), 'class' => i.zero? ? 'GreetingJob' : 'FlakyJob', 'queue' => 'default',
            'args' => [i] }
    payload = JSON.generate('queue' => 'default', 'payload' => job, 'run_at' => Time.now.to_i - 5)
    c.hset("cogworker:workers:#{identity}", 'thread-1', payload)
    c.expire("cogworker:workers:#{identity}", 600)
  end
end

# ---- Retries: jobs that have failed at least once but still have retries left ----
retry_errors = [
  ['RuntimeError', 'simulated failure (attempt 1 of 2)'],
  ['Net::OpenTimeout', 'execution expired'],
  ['Redis::CannotConnectError', 'connection refused']
]
Cogworker.config.redis do |c|
  retry_errors.each_with_index do |(err_class, msg), i|
    job = { 'jid' => SecureRandom.hex(12), 'class' => 'FlakyJob', 'queue' => 'default', 'args' => [i],
            'retry' => 3, 'retry_count' => i + 1, 'error_class' => err_class, 'error_message' => msg,
            'failed_at' => Time.now.to_f - (i * 60) }
    c.zadd('cogworker:retry', Time.now.to_f + (60 * (i + 1)), JSON.generate(job))
  end
end

# ---- Dead: jobs that exhausted all retries (fictional classes — these are
#      pure display records, never re-executed, so they don't need to
#      correspond to real loaded Ruby classes) ----
dead_jobs = [
  ['SendWelcomeEmailJob', [{ 'user_id' => 42 }], 'Net::SMTPAuthenticationError', '535 authentication failed'],
  ['ChargeCardJob', [{ 'order_id' => 991, 'amount_cents' => 2500 }], 'Stripe::CardError', 'Your card was declined.'],
  ['SyncInventoryJob', [{ 'sku' => 'ABC-123' }], 'Timeout::Error', 'execution expired']
]
Cogworker.config.redis do |c|
  dead_jobs.each_with_index do |(klass, args, err_class, msg), i|
    job = { 'jid' => SecureRandom.hex(12), 'class' => klass, 'queue' => 'default', 'args' => args,
            'retry' => 0, 'retry_count' => 1, 'error_class' => err_class, 'error_message' => msg }
    c.zadd('cogworker:dead', Time.now.to_f - (i * 3600), JSON.generate(job))
  end
end

# ---- History: a generous, pagination-worthy mix of past runs (also
#      fictional classes where convenient — same reasoning as Dead above) ----
history_classes = %w[GreetingJob FlakyJob DailyReportJob SendWelcomeEmailJob ChargeCardJob SyncInventoryJob
                     GenerateReportJob]
failures = [
  ['RuntimeError', 'simulated failure',
   ["examples/jobs/flaky_job.rb:20:in 'perform'", "lib/cogworker/processor.rb:54:in 'block in execute'"]],
  ['Net::OpenTimeout', 'execution expired',
   ["/usr/lib/ruby/net/http.rb:1000:in 'initialize'", "app/jobs/sync_inventory_job.rb:12:in 'perform'"]],
  ['Stripe::CardError', 'Your card was declined.', ["app/jobs/charge_card_job.rb:8:in 'perform'"]]
]
history_count = 40
Cogworker.config.redis do |c|
  history_count.times do |i|
    finished_at = Time.now.to_f - (i * 900) # spread 15 minutes apart, going back in time
    started_at = finished_at - rand(0.01..2.5)
    failed = (i % 4).zero? # ~25% failure rate
    entry = {
      'jid' => SecureRandom.hex(12), 'class' => history_classes.sample, 'queue' => 'default',
      'args' => [{ 'seed_index' => i }], 'status' => failed ? 'failed' : 'success',
      'started_at' => started_at, 'finished_at' => finished_at
    }
    if failed
      error_class, message, backtrace = failures.sample
      entry.merge!('error_class' => error_class, 'error_message' => message, 'backtrace' => backtrace)
    end
    raw = JSON.generate(entry)
    c.zadd('cogworker:history:all', finished_at, raw)
    c.zadd("cogworker:history:#{entry['status']}", finished_at, raw)
  end
end

# ---- Stats counters (Queue/Retry/Scheduled/Dead sizes are derived live
#      from the sets above; processed/failed are plain counters) ----
Cogworker.config.redis do |c|
  c.set('cogworker:stats:processed', 30)
  c.set('cogworker:stats:failed', 10)
end

puts <<~SUMMARY
  Seeded demo data for every tab:
    Queues:    5 GreetingJob on "default", 3 LowPriorityJob on "low"
    Scheduled: 4 jobs at various future times
    Periodic:  #{periodic_entries.size} registered cron schedules
    Workers:   2 fake in-flight workers (no real process behind them)
    Retries:   #{retry_errors.size} jobs mid-retry
    Dead:      #{dead_jobs.size} exhausted jobs
    History:   #{history_count} past runs, ~25% failed — spans multiple pages

  Web UI: bundle exec rackup ./examples/config.ru -p 9394
          then open http://localhost:9394/cogworker
SUMMARY
