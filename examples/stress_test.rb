# frozen_string_literal: true

# Stress/load tool for the three places CLAUDE.md calls out as worth
# hammering under real concurrency: job throughput, the Web UI under
# concurrent requests (optionally with COGWORKER_RELOAD=true, the reload
# race spec.rb/web_reload_spec.rb regression-tests), and Periodic::Ticker
# racing for the same cron slot. Not part of the examples/ demo app — it
# uses its own Redis db (COGWORKER_STRESS_REDIS_URL, default db 14) so it
# never touches db 0 (the demo app) or db 15 (the spec suite), and flushes
# that db before every scenario it runs.
#
#   bundle exec ruby ./examples/stress_test.rb throughput
#   bundle exec ruby ./examples/stress_test.rb web [--reload]
#   bundle exec ruby ./examples/stress_test.rb periodic
#   bundle exec ruby ./examples/stress_test.rb all
#
# bundle exec ruby ./examples/stress_test.rb -h   # every option, with defaults

require 'cogworker'
require 'rbconfig'
require 'optparse'
require 'json'
require 'securerandom'

REDIS_URL = ENV.fetch('COGWORKER_STRESS_REDIS_URL', 'redis://localhost:6379/14')

opts = {
  jobs: 20_000, concurrency: 25, producers: 8, queues: ['default'], work_ms: 0, failure_rate: 0.0,
  web_threads: 32, web_duration: 15, reload: false,
  tickers: 40, entries: 20, rounds: 25,
  redis_url: REDIS_URL
}

OptionParser.new do |o|
  o.banner = 'Usage: stress_test.rb [throughput|web|periodic|all] [options]'
  o.on('--jobs=N', Integer, 'throughput: jobs to push and process (default 20000)') { |v| opts[:jobs] = v }
  o.on('--concurrency=N', Integer, 'throughput: Manager thread pool size (default 25)') { |v| opts[:concurrency] = v }
  o.on('--producers=N', Integer, 'throughput: concurrent pushing threads (default 8)') { |v| opts[:producers] = v }
  o.on('--queues=a,b,c', Array, 'throughput: weighted queue list, e.g. default,default,low') { |v| opts[:queues] = v }
  o.on('--work-ms=N', Integer, 'throughput: simulated per-job work (default 0)') { |v| opts[:work_ms] = v }
  o.on('--failure-rate=F', Float, 'throughput: fraction of jobs that raise (default 0.0)') do |v|
    opts[:failure_rate] = v
  end
  o.on('--web-threads=N', Integer, 'web: concurrent request threads (default 32)') { |v| opts[:web_threads] = v }
  o.on('--web-duration=N', Integer, 'web: seconds to hammer for (default 15)') { |v| opts[:web_duration] = v }
  o.on('--reload', 'web: run under COGWORKER_RELOAD=true, in a subprocess') { opts[:reload] = true }
  o.on('--tickers=N', Integer, 'periodic: simulated racing processes (default 40)') { |v| opts[:tickers] = v }
  o.on('--entries=N', Integer, 'periodic: distinct cron entries per round (default 20)') { |v| opts[:entries] = v }
  o.on('--rounds=N', Integer, 'periodic: independent races to run (default 25)') { |v| opts[:rounds] = v }
  o.on('--redis-url=URL', "override #{REDIS_URL.inspect}") { |v| opts[:redis_url] = v }
end.parse!(ARGV)

command = ARGV.shift || 'all'
unless %w[throughput web periodic all].include?(command)
  warn "unknown command #{command.inspect} (want throughput|web|periodic|all)"
  exit 1
end

def reset_config!(redis_url)
  Cogworker.instance_variable_set(:@config, nil)
  Cogworker.instance_variable_set(:@server_process, nil)
  Cogworker.server_process!
  Cogworker.config.redis = { url: redis_url }
end

def section(title)
  puts "\n== #{title} =="
end

# ---------------------------------------------------------------------------
# Throughput: push `jobs` jobs from `producers` concurrent threads, then run
# a real Manager (config.concurrency processors, weighted `queues`) until
# every pushed job has been accounted for (processed + failed), timing both
# phases separately.
# ---------------------------------------------------------------------------
class StressJob
  include Cogworker::Worker

  def perform(_index, work_ms, failure_rate)
    sleep(work_ms / 1000.0) if work_ms.positive?
    raise 'simulated stress failure' if failure_rate.positive? && rand < failure_rate
  end
end

# Direct Cogworker::Client.push, not StressJob.perform_async: the DSL's
# `cogworker_options queue:` writes to a class-level Hash shared by every
# producer thread -- setting it per-push here would race between threads
# (one thread's queue choice clobbering another's between its own
# `cogworker_options` and `perform_async` calls). Building the job hash
# directly sidesteps that shared mutable state entirely.
def push_producer_batch(offset, count, queue_names, opts)
  count.times do |i|
    queue = queue_names[(offset + i) % queue_names.size]
    Cogworker::Client.push('class' => 'StressJob', 'queue' => queue, 'retry' => 1,
                           'args' => [i, opts[:work_ms], opts[:failure_rate]])
  end
end

def producer_job_counts(jobs, producers)
  base = jobs / producers
  remainder = jobs - (base * producers)
  Array.new(producers) { |p| base + (p < remainder ? 1 : 0) }
end

def push_stress_jobs(opts)
  queue_names = opts[:queues].uniq
  counts = producer_job_counts(opts[:jobs], opts[:producers])

  wall_time do
    threads = counts.each_with_index.map { |count, p| Thread.new { push_producer_batch(p, count, queue_names, opts) } }
    threads.each(&:join)
  end
end

def stats_snapshot
  Cogworker.config.redis do |c|
    [c.get(Cogworker::RedisKeys::STATS_PROCESSED).to_i, c.get(Cogworker::RedisKeys::STATS_FAILED).to_i]
  end
end

def jobs_drained?(jobs, processed_before, failed_before)
  processed, failed = stats_snapshot
  (processed - processed_before) + (failed - failed_before) >= jobs
end

def process_stress_jobs(opts)
  processed_before, failed_before = stats_snapshot
  manager = Cogworker::Manager.new
  elapsed = wall_time do
    manager.start!
    wait_for(timeout: [opts[:jobs] / 20, 30].max) { jobs_drained?(opts[:jobs], processed_before, failed_before) }
  end
  manager.stop!(timeout: 10)
  elapsed
end

# Also sizes the Redis pool (concurrency + 5, see Config#redis_pool) -- keep
# --producers within that headroom or producer threads will block on a
# connection checkout during the push phase.
def configure_throughput!(opts)
  reset_config!(opts[:redis_url])
  Cogworker.config.queues = opts[:queues]
  Cogworker.config.concurrency = opts[:concurrency]
  Cogworker.config.redis(&:flushdb)
end

def print_rate(label, count, elapsed, suffix: nil)
  puts format('%<label>s %<n>d jobs in %<s>.2fs (%<r>.0f jobs/sec)%<suffix>s',
              label: label, n: count, s: elapsed, r: count / elapsed, suffix: suffix ? " #{suffix}" : '')
end

def run_throughput(opts)
  section("Throughput: #{opts[:jobs]} jobs, concurrency=#{opts[:concurrency]}, " \
          "queues=#{opts[:queues].join(',')}, work_ms=#{opts[:work_ms]}, failure_rate=#{opts[:failure_rate]}")

  configure_throughput!(opts)
  print_rate('pushed', opts[:jobs], push_stress_jobs(opts))
  print_rate('processed', opts[:jobs], process_stress_jobs(opts), suffix: "(concurrency=#{opts[:concurrency]})")
end

# ---------------------------------------------------------------------------
# Web UI: seed every tab with realistic data, then hammer Cogworker::Web.call
# from many threads with a mix of plain and htmx-fragment (HX-Request)
# requests. `--reload` re-runs this in a subprocess with COGWORKER_RELOAD=true
# set *before* `require 'cogworker'` (Zeitwerk requires enable_reloading
# before setup — can't be toggled inside this already-running process), the
# same way spec/cogworker/web_reload_spec.rb does, since that's the whole
# point: every request there re-triggers Cogworker::LOADER.reload, which is
# exactly the concurrency hazard CLAUDE.md documents (Web::RELOAD_MUTEX).
# ---------------------------------------------------------------------------
WEB_SEED_SOURCE = <<~'RUBY'
  Cogworker.config.redis do |c|
    5.times { |i| c.lpush('cogworker:queue:default', JSON.generate('jid' => SecureRandom.hex(12),
      'class' => 'GreetingJob', 'queue' => 'default', 'args' => [i])) }
    3.times { |i| c.lpush('cogworker:queue:low', JSON.generate('jid' => SecureRandom.hex(12),
      'class' => 'LowPriorityJob', 'queue' => 'low', 'args' => [i])) }
    c.sadd('cogworker:queues', %w[default low])

    4.times do |i|
      job = { 'jid' => SecureRandom.hex(12), 'class' => 'GreetingJob', 'queue' => 'default', 'args' => [i] }
      c.zadd('cogworker:schedule', Time.now.to_f + (30 * (i + 1)), JSON.generate(job))
    end

    3.times do |i|
      job = { 'jid' => SecureRandom.hex(12), 'class' => 'FlakyJob', 'queue' => 'default', 'args' => [i],
              'retry' => 3, 'retry_count' => i + 1, 'error_class' => 'RuntimeError', 'error_message' => 'boom',
              'failed_at' => Time.now.to_f - (i * 60) }
      c.zadd('cogworker:retry', Time.now.to_f + (60 * (i + 1)), JSON.generate(job))
    end

    3.times do |i|
      job = { 'jid' => SecureRandom.hex(12), 'class' => 'DeadJob', 'queue' => 'default', 'args' => [i],
              'retry' => 0, 'retry_count' => 1, 'error_class' => 'RuntimeError', 'error_message' => 'boom' }
      c.zadd('cogworker:dead', Time.now.to_f - (i * 3600), JSON.generate(job))
    end

    identities = Array.new(3) { |i| "stress-host:#{7000 + i}:#{SecureRandom.hex(6)}" }
    identities.each_with_index do |identity, i|
      info = { 'hostname' => 'stress-host', 'pid' => 7000 + i, 'concurrency' => 5, 'queues' => %w[default low],
                'started_at' => Time.now.to_f - 3600, 'rss_kb' => 90_000 }
      c.sadd('cogworker:processes', identity)
      c.hset("cogworker:process:#{identity}", 'info', JSON.generate(info), 'busy', '1', 'quiet', 'false')
      c.expire("cogworker:process:#{identity}", 600)
      job = { 'jid' => SecureRandom.hex(12), 'class' => 'GreetingJob', 'queue' => 'default', 'args' => [i] }
      payload = JSON.generate('queue' => 'default', 'payload' => job, 'run_at' => Time.now.to_i - 5)
      c.hset("cogworker:workers:#{identity}", 'thread-1', payload)
      c.expire("cogworker:workers:#{identity}", 600)
    end

    pjid = SecureRandom.hex(10)
    c.hset('periodic:schedule', pjid, JSON.generate('cron' => '*/5 * * * *', 'class' => 'DailyReportJob',
      'retry' => 0, 'unique' => 'until_executed', 'args' => []))
    c.set("periodic:last_slot:#{pjid}", Time.now.to_i - 240)

    60.times do |i|
      finished_at = Time.now.to_f - (i * 900)
      failed = (i % 4).zero?
      entry = { 'jid' => SecureRandom.hex(12), 'class' => 'GreetingJob', 'queue' => 'default', 'args' => [i],
                'status' => failed ? 'failed' : 'success', 'started_at' => finished_at - 0.5,
                'finished_at' => finished_at }
      entry.merge!('error_class' => 'RuntimeError', 'error_message' => 'boom', 'backtrace' => ['a.rb:1']) if failed
      raw = JSON.generate(entry)
      c.zadd('cogworker:history:all', finished_at, raw)
      c.zadd("cogworker:history:#{entry['status']}", finished_at, raw)
    end

    c.set('cogworker:stats:processed', 500)
    c.set('cogworker:stats:failed', 60)
  end
RUBY

WEB_HAMMER_SOURCE = <<~'RUBY'
  routes = ['/', '/overview', '/overview?layout=a&period=week', '/overview?layout=b&queue=default',
            '/overview?layout=b&queue=low', '/jobs', '/jobs?status=Retrying', '/jobs?status=Dead',
            '/schedules', '/workers', '/history', '/history/data',
            '/overview/redis', '/overview/throughput_data', '/overview/runs_data?period=week']
  web = Cogworker::Web # captured once, matching how Rack::URLMap holds it in real usage
  stats = Hash.new(0)
  latencies = []
  errors = []
  mutex = Mutex.new
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + WEB_DURATION

  threads = WEB_THREADS.times.map do
    Thread.new do
      while Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
        path = routes.sample
        env = Rack::MockRequest.env_for(path, [true, false].sample ? { 'HTTP_HX_REQUEST' => 'true' } : {})
        t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        begin
          status, = web.call(env)
          elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
          mutex.synchronize { stats[status] += 1; latencies << elapsed }
        rescue StandardError => e
          mutex.synchronize { errors << "#{path}: #{e.class}: #{e.message}" }
        end
      end
    end
  end
  threads.each(&:join)

  total = stats.values.sum
  sorted = latencies.sort
  pct = ->(p) { sorted.empty? ? 0 : sorted[[(sorted.size * p).to_i, sorted.size - 1].min] }
  puts 'STRESS_WEB_RESULT ' + JSON.generate(
    total: total, by_status: stats, errors: errors.uniq.first(20),
    req_per_sec: (total / WEB_DURATION.to_f).round(1),
    p50_ms: (pct.call(0.50) * 1000).round(2), p95_ms: (pct.call(0.95) * 1000).round(2),
    p99_ms: (pct.call(0.99) * 1000).round(2), max_ms: ((sorted.last || 0) * 1000).round(2)
  )
RUBY

def build_web_script(opts)
  <<~RUBY
    require 'cogworker'
    require 'rack/mock'
    require 'securerandom'
    Cogworker.config.redis = { url: #{opts[:redis_url].inspect} }
    Cogworker::Web # bare reference, not `require` -- see CLAUDE.md's Zeitwerk section

    #{WEB_SEED_SOURCE}

    WEB_THREADS = #{opts[:web_threads]}
    WEB_DURATION = #{opts[:web_duration]}
    #{WEB_HAMMER_SOURCE}
  RUBY
end

def exit_with(message)
  warn message
  exit 1
end

def run_ruby_subprocess(env, script)
  lib = File.expand_path('../lib', __dir__)
  lines = []
  IO.popen(env, [RbConfig.ruby, '-I', lib, '-e', script], err: %i[child out]) { |io| lines = io.readlines }
  [lines, $?.success?] # rubocop:disable Style/SpecialGlobalVars
end

def spawn_web_subprocess(script, opts)
  env = opts[:reload] ? { 'COGWORKER_RELOAD' => 'true' } : {}
  lines, ok = run_ruby_subprocess(env, script)
  lines.each { |line| puts "  #{line}" unless line.start_with?('STRESS_WEB_RESULT') }
  result_line = lines.find { |line| line.start_with?('STRESS_WEB_RESULT') }

  exit_with('web scenario subprocess failed') unless ok
  exit_with('web scenario subprocess produced no result') unless result_line
  JSON.parse(result_line.sub('STRESS_WEB_RESULT ', ''))
end

def print_web_errors(errors)
  if errors.any?
    puts "errors (#{errors.size}):"
    errors.each { |e| puts "  #{e}" }
  else
    puts 'no errors'
  end
end

def print_web_result(result, opts)
  puts format('%<n>d requests in %<d>ds (%<r>.1f req/sec) -- status: %<s>s',
              n: result['total'], d: opts[:web_duration], r: result['req_per_sec'], s: result['by_status'])
  puts format('latency p50=%<p50>.2fms p95=%<p95>.2fms p99=%<p99>.2fms max=%<max>.2fms',
              p50: result['p50_ms'], p95: result['p95_ms'], p99: result['p99_ms'], max: result['max_ms'])
  print_web_errors(result['errors'])
end

def run_web(opts)
  section("Web UI: #{opts[:web_threads]} threads for #{opts[:web_duration]}s, reload=#{opts[:reload]}")

  Cogworker.config.redis = { url: opts[:redis_url] } # only to flush before handing off to the child
  Cogworker.config.redis(&:flushdb)

  result = spawn_web_subprocess(build_web_script(opts), opts)
  print_web_result(result, opts)
end

# ---------------------------------------------------------------------------
# Periodic: `tickers` independent Ticker instances (simulating that many
# worker processes) race, at the same instant, to claim `entries` distinct
# cron slots -- repeated for `rounds` independent races (fresh pjids each
# round, so real wall-clock minute boundaries don't limit how many races a
# short run can exercise). Exactly one ticker should win each entry every
# time; any other count is the exact double-fire/never-fires bug
# claim.lua/CLAUDE.md's "exactly-once-per-tick" note exists to prevent.
# ---------------------------------------------------------------------------
class AlwaysRunningManager
  def stopping?
    false
  end

  def quiet?
    false
  end
end

def build_race_entries(round, count)
  Array.new(count) do |i|
    Cogworker::Periodic::Entry.new(cron: '* * * * *', class_name: "StressPeriodicJob#{round}_#{i}",
                                   retry: 0, unique: i.even? ? :until_executed : nil,
                                   args: [{ 'round' => round, 'i' => i }])
  end
end

# Lets `size` threads all reach `arrive_and_wait` before any of them
# proceeds, so a simulated race genuinely starts at once instead of
# trickling in one thread at a time.
class ReadyGate
  def initialize(size)
    @size = size
    @ready = 0
    @mutex = Mutex.new
    @go = false
  end

  def arrive_and_wait
    @mutex.synchronize { @ready += 1 }
    sleep(0.0005) until @go
  end

  def release_when_full
    sleep(0.001) until @mutex.synchronize { @ready } == @size
    @go = true
  end
end

# `tickers` independent Ticker instances (simulating that many processes),
# all holding the same `entries`, racing to claim each one at once.
def race_tickers(tickers, entries, fake_manager)
  gate = ReadyGate.new(tickers)
  threads = tickers.times.map do
    Thread.new do
      ticker = Cogworker::Periodic::Ticker.new(fake_manager, entries)
      gate.arrive_and_wait
      ticker.send(:tick)
    end
  end
  gate.release_when_full
  threads.each(&:join)
end

def tally_wins
  wins = Hash.new(0)
  Cogworker.config.redis { |c| c.lrange('cogworker:queue:default', 0, -1) }.each do |raw|
    wins[JSON.parse(raw)['periodic_pjid']] += 1
  end
  wins
end

def race_round(round, opts, fake_manager)
  Cogworker.config.redis(&:flushdb)
  entries = build_race_entries(round, opts[:entries])
  race_tickers(opts[:tickers], entries, fake_manager)

  wins = tally_wins
  entries.filter_map do |entry|
    count = wins[entry.pjid]
    "round #{round} #{entry.pjid}: #{count} winners (expected 1)" if count != 1
  end
end

# Sizes the Redis pool (concurrency + 5, see Config#redis_pool) so that
# `tickers` concurrent threads racing each other in a round never block on a
# connection checkout -- pool sizing is otherwise unrelated to Manager
# concurrency here, since no Manager is started in this scenario.
def configure_periodic!(opts)
  reset_config!(opts[:redis_url])
  Cogworker.config.concurrency = opts[:tickers]
  Cogworker.config.redis(&:flushdb)
end

def print_periodic_result(total_races, elapsed, opts, mismatches)
  puts format('%<r>d races (%<t>d tickers each) in %<s>.2fs (%<v>.0f races/sec)',
              r: total_races, t: opts[:tickers], s: elapsed, v: total_races / elapsed)
  if mismatches.empty?
    puts "all #{total_races} races had exactly one winner"
  else
    puts "#{mismatches.size} mismatches:"
    mismatches.first(20).each { |m| puts "  #{m}" }
  end
end

def run_periodic(opts)
  section("Periodic: #{opts[:tickers]} tickers x #{opts[:entries]} entries x #{opts[:rounds]} rounds")
  configure_periodic!(opts)

  fake_manager = AlwaysRunningManager.new
  mismatches = []
  elapsed = wall_time do
    opts[:rounds].times { |round| mismatches.concat(race_round(round, opts, fake_manager)) }
  end

  print_periodic_result(opts[:rounds] * opts[:entries], elapsed, opts, mismatches)
end

def wait_for(timeout:)
  deadline = Time.now + timeout
  loop do
    result = yield
    return result if result
    raise "timed out after #{timeout}s waiting for condition" if Time.now > deadline

    sleep 0.05
  end
end

def wall_time
  start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  yield
  Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
end

puts "Using Redis at #{opts[:redis_url]} (dedicated stress db -- flushed before each scenario)"

run_throughput(opts) if %w[throughput all].include?(command)
run_web(opts) if %w[web all].include?(command)
run_periodic(opts) if %w[periodic all].include?(command)
