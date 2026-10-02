# Cogworker

Redis-backed background job processing for Ruby. It includes a worker DSL,
retries with backoff, delayed and periodic (cron) jobs, unique jobs, job
status and run history, a multi-process supervisor with phased restarts, a
Web UI, and a Prometheus exporter.

- Ruby ≥ 3.1, Redis
- The Web UI works fully offline. htmx, its stylesheet, fonts, icons, AG Grid
  and Chart.js all ship inside the gem, with no CDN.
- MIT license

## Installation

```ruby
# Gemfile
gem 'cogworker'
```

```sh
bundle install
```

## Quick start

### 1. Define a job

```ruby
class GreetingJob
  include Cogworker::Worker   # or Cogworker::Job, the same module

  def perform(name)
    Cogworker.logger.info { "Hello, #{name}!" }
  end
end
```

Arguments are serialized as JSON, so pass only simple values: strings,
numbers, `true`/`false`/`nil`, arrays and hashes. Hash keys arrive in
`perform` as **strings**, so don't use keyword arguments (`**opts`) in
`perform`.

### 2. Enqueue it

```ruby
jid = GreetingJob.perform_async('world')         # now
GreetingJob.perform_in(300, 'world')             # in 5 minutes
GreetingJob.perform_at(Time.now + 3600, 'world') # at a specific time

# Low-level, without a job class method:
Cogworker::Client.push('class' => 'GreetingJob', 'args' => ['world'], 'queue' => 'default')
```

### 3. Write an init file

```ruby
# config/cogworker.rb
require 'cogworker'
require_relative '../app/jobs/greeting_job'

Cogworker.configure_server do |config|
  config.redis = { url: ENV.fetch('REDIS_URL', 'redis://localhost:6379/0') }
end

Cogworker.configure_client do |config|
  config.redis = { url: ENV.fetch('REDIS_URL', 'redis://localhost:6379/0') }
end
```

The `configure_server` block runs only in a worker process (one started via
`exe/cogworker`/`exe/cogworkerswarm`). The `configure_client` block runs only
in every other process (web app, console). This lets one file be loaded in
both places.

Redis options are `url:`, or `host:`/`port:`/`password:`/`db:`. On the
server, the connection pool size is `concurrency + 5`.

Load your job classes up front, in the init file, rather than leaving them to
an autoloader. A worker resolves a job's class on whichever of its threads
picks the job up, so with an autoloader that isn't thread-safe, two threads
can race to load the same class and one of them sees it half-defined
(`undefined method 'perform'`). With Rails, keep `config.eager_load = true`
in the environment the worker runs in; with Zeitwerk on its own, call
`loader.eager_load` after `loader.setup`. Classes named in
`config.periodic` are resolved on the main thread at boot either way, and one
that can't be found is logged as a warning.

### 4. Start a worker

```sh
bundle exec cogworker -r ./config/cogworker.rb -C ./config/cogworker.yml
```

## Process configuration

### CLI flags

| Flag | Purpose |
|---|---|
| `-r, --require PATH` | the app's init file (or a directory, in which case `PATH/config/environment` is required) |
| `-C, --config PATH` | YAML config file (see below) |
| `-c, --concurrency N` | number of worker threads (default 10) |
| `-q, --queue NAME[,WEIGHT]` | a queue with an optional weight; repeatable; overrides `:queues:` from the config file |
| `-L, --logfile PATH` | write the log to a file |
| `-e, --environment ENV` | environment (default `APP_ENV`/`RAILS_ENV`/`RACK_ENV`/`development`); exported as `APP_ENV`, `RAILS_ENV` and `RACK_ENV` before the config file and app code are loaded |

### YAML config

The file is rendered through ERB before it is parsed:

```yaml
---
:concurrency: <%= ENV["CONCURRENCY"] || 5 %>
:queues:
  - default
  - default   # repeating a queue sets its weight: default is polled twice as often as low
  - low
:fetch: reliable   # or basic — see "Fetch modes" below
```

CLI flags take precedence over the file.

### Signals

| Signal | Effect |
|---|---|
| `TSTP` | quiet: stop fetching new jobs; jobs already running are finished |
| `TERM` / `INT` | graceful stop: wait for running jobs (up to 25 s), put any still unfinished back on their queues, then exit |

### Fetch modes

`config.fetch` (or `:fetch:` in the YAML file) picks how workers take jobs
off their queues:

- `:reliable` (default, needs Redis >= 6.2): a job is moved atomically onto
  the process's own in-progress list and stays there until it has finished.
  If the process dies mid-job (OOM, `SIGKILL`, a lost host), the job is put
  back on its queue by another live process once the dead one has gone
  `config.orphan_threshold` without a heartbeat (default 5 minutes, then up
  to a minute until the next check). The threshold is deliberately well
  above the heartbeat's own 60 s expiry: a process that is alive but
  couldn't reach Redis for a while (an outage, a failover) mustn't have its
  running jobs started a second time elsewhere. Lower it if crashed
  processes' jobs must come back sooner; raise it if Redis blips longer
  than that are expected. A worker with a single queue waits on Redis
  for jobs (`BLMOVE`), picking a new one up immediately. With several
  (weighted) queues they are polled instead: while they stay empty, each
  worker thread waits 0.25 s, then
  0.5 s, … up to `config.fetch_idle_max_interval` (default 1 s) between
  polls, and goes back to 0.25 s as soon as it finds a job. That cap is the
  longest an idle worker takes to notice a new job; lower it (e.g. `0.25`)
  if that matters more than how often idle workers poll Redis.
- `:basic`: a single blocking `BRPOP` across all queues, as in earlier
  versions. A job popped by a process that then dies is lost.

On Redis older than 6.2, `:reliable` falls back to `:basic` with a warning —
checked when workers start, and again on the first fetch if the server turns
out not to support it after all. A worker doesn't start taking jobs until it
has registered itself in Redis, so with Redis unreachable at boot it waits
(and still stops on `TERM`).
Either way delivery is *at least once*: a job that was partly done when its
process died or was stopped runs again from the start, so make jobs safe to
repeat. A job is never re-run because of a Redis error *after* it ran,
though: once it has run, it is acknowledged (and on failure recorded in
Retry/Dead); if even recording the failure fails, it goes to Retry with a
short delay — to Dead after 3 such interruptions — never straight back onto
its queue.

### Multiple processes (swarm)

```sh
COGWORKER_COUNT=4 PHASED_RESTART=true \
  bundle exec cogworkerswarm -r ./config/cogworker.rb -C ./config/cogworker.yml
```

`cogworkerswarm` accepts the same flags as `cogworker`. It forks
`COGWORKER_COUNT` child processes and restarts any that die. A child that
keeps crashing within 30 s of starting is restarted with an exponential
backoff (1 s, 2 s, 4 s, … up to 60 s) instead of in a tight loop. With
`PHASED_RESTART=true`, sending `USR2` to the parent restarts the children one
at a time, so processing never stops. `TERM`/`INT` are forwarded to all
children.

## Job options

```ruby
class ReportJob
  include Cogworker::Worker

  cogworker_options queue: 'low', retry: 5
end
```

| Option | Meaning |
|---|---|
| `queue:` | queue name (default `default`) |
| `retry:` | `true` or unset: 25 attempts; an integer: that many retries; `false` or `0`: straight to Dead |
| `unique: :until_executed` | don't enqueue a duplicate (same class + queue + args) until the previous one has finished |

Subclasses inherit options. Any other keys (for example
`lock_run: :while_executing`) are copied unchanged into the job hash, where
your own middleware can read them.

### Job arguments

Arguments are stored as JSON and are neither validated nor coerced on the
way in, so `perform` receives whatever survives a JSON round trip: Symbols
come back as Strings, Hash keys as Strings, and objects like `Time` as their
`to_s`. Pass plain JSON types (String, Integer, Float, `true`/`false`/`nil`,
Array, Hash with String keys) to get back exactly what you pushed.
`Cogworker.strict_args!` is accepted but does nothing: since there's no
coercion, there's nothing to make stricter.

`Testing.fake!`/`inline!` skip that round trip, so a test can pass while a
real worker would receive Strings instead of Symbols.

### Retries and Dead

A failed job moves to the Retry set with a growing delay
(`count**4 + 15 + jitter` seconds). When it runs out of attempts, it moves to
Dead. You can put it back on its queue by hand from the Web UI.

### Unique jobs

With `unique: :until_executed`, calling `perform_async` again with the same
arguments returns `nil` instead of a jid while the original job is still
enqueued or running. The lock is released when the job succeeds or fails for
the last time. In case a process crashes, the lock also has a safety TTL,
`config.unique_lock_ttl` (default 24 h), counted from when the job is due (so
a `perform_in` further out than that keeps its lock) and extended by the
backoff each time an attempt fails and will be retried.

## Middleware

There are two chains: the client chain runs when a job is enqueued, and the
server chain runs around `perform`.

```ruby
class TimingMiddleware
  # server: call(worker, job, queue)
  def call(_worker, job, queue)
    start = Time.now
    yield
    Cogworker.logger.info { "#{job['class']} on #{queue}: #{Time.now - start}s" }
  end
end

class TagMiddleware
  # client: call(worker_class, job, queue, redis_pool)
  def call(_worker_class, job, _queue, _redis_pool)
    job['tags'] = ['api']
    yield
  end
end

Cogworker.configure_server do |config|
  config.server_middleware { |chain| chain.add(TimingMiddleware) }
end

Cogworker.configure_client do |config|
  config.client_middleware { |chain| chain.add(TagMiddleware) }
end
```

`chain.add(Klass, *args)` passes `args` to the constructor. A new middleware
instance is created for every call, so keep any state shared between jobs at
the class level.

## Periodic jobs (cron)

```ruby
Cogworker.configure_server do |config|
  config.periodic do |mgr|
    mgr.register '0 * * * *',   'HourlyCleanupJob'
    mgr.register '*/5 * * * *', 'DailyReportJob', retry: 0, unique: :until_executed,
                                                  args: [{ section: 'digest' }]
  end
end
```

Each schedule slot runs **exactly once**, no matter how many processes are
running. Processes claim a slot atomically in Redis, with no leader. With
`unique: :until_executed`, a new slot is skipped while the previous run is
still in progress. If the process running it dies (OOM, `SIGKILL`), the entry
frees itself within a minute, since that lock is kept alive by the running
process's heartbeat.

On first start against an empty Redis, each entry's most recent due slot
fires right away. To turn that off, set `config.periodic_catch_up = false`.

## Job status

```ruby
Cogworker.configure_server do |config|
  Cogworker::Status.configure_server_middleware(config, expiration: 1800)
end
Cogworker.configure_client do |config|
  Cogworker::Status.configure_client_middleware(config, expiration: 1800)
end

class ImportJob
  include Cogworker::Worker
  include Cogworker::Status::Worker

  def perform(file)
    at(50, 'half way')             # progress percentage + message
    store('rows' => 1000)          # arbitrary fields
  end
end

Cogworker::Status.status(jid) # => :queued | :working | :retrying | :complete | :failed (nil if unknown)
Cogworker::Status.get(jid)    # => the full hash: status, pct, message, ...
```

Status is stored in Redis with a TTL of `expiration` seconds.

## Run history

Status holds only the current state. History records every finished run:
its arguments, its duration and, on failure, the error class, message and
backtrace. You can browse it on the Web UI's History tab.

```ruby
Cogworker.configure_server do |config|
  Cogworker::History.configure_server_middleware(
    config,
    retention_days: 30,              # the main trim: by age
    max_entries: 50_000,             # safety ceiling by count
    daily_stats_retention_days: 400  # counters behind the "Runs per day" chart
  )
end
```

## Web UI

```ruby
# config.ru
require_relative 'config/cogworker'

Cogworker::Web.time_format = '%d.%m.%Y %H:%M:%S'  # timestamp format (strftime)
Cogworker::Web.live_update_interval = 5           # auto-refresh interval, seconds
Cogworker::Web.history_per_page = 50              # rows per History page

map '/cogworker' do
  run Cogworker::Web
end
```

Tabs:

- **Overview**: counters, latency per queue, the queue list (browse, delete,
  pause, retry all), a 24-hour throughput chart, a "Runs per day" chart, and
  Redis info. A second "Queue first" layout shows one queue in detail.
- **Jobs**: every job in one table (enqueued, running, scheduled, retrying,
  dead), with a status filter, search, and a detail panel (args, attempt
  history, last error, retry/reschedule/delete).
- **Schedules**: periodic jobs with their last and next run, plus
  "Run now" and "Disable"/"Enable" buttons.
- **Workers**: live processes (queues, load, memory, heartbeat,
  quiet/resume/stop) and the jobs running right now.
- **History**: the run log, with server-side sorting, filtering and
  paging, and backtraces for failed runs.

The header also has these controls:

- **Live** toggles auto-refresh on every tab at once.
- **Pause intake** / **Resume intake** quiet or resume every worker process
  at once.
- A width toggle switches between fixed-width and full-width layout.

Timestamps are shown in the browser's time zone. Every button also works
without JavaScript.

### Authentication and custom middleware

```ruby
Cogworker::Web.use(MyAuthMiddleware)   # wraps the whole Web UI app
```

Unsafe methods (POST etc.) are accepted only with
`Sec-Fetch-Site: same-origin`. To allow an exception (for example, an SSO
callback), override `Cogworker::Web.safe_request?(env)`.

The Web UI's session cookie (used only by middleware you add with `.use`) is
skipped automatically when the app mounting the Web UI already has a session
(the middleware then reads and writes the app's own session), and can be
turned off with `Cogworker::Web.builtin_session = false`. It is signed with a
random per-process secret by default. When running several
web processes (e.g. Puma workers), set the same secret for all of them —
`Cogworker::Web.session_secret = '...'` (at least 64 characters) or the
`COGWORKER_SESSION_SECRET` environment variable.

### Extensions

```ruby
module MyTab
  def self.registered(app)
    app.get('/my_tab') { ... }
  end
end

Cogworker::Web.register(MyTab, tab: 'My tab', index: 'my_tab')
```

## Prometheus

The Web UI serves `GET <mount>/metrics` in Prometheus text format. The
metrics are:

- `cogworker_processed_total`
- `cogworker_failed_total`
- `cogworker_retry_size`
- `cogworker_scheduled_size`
- `cogworker_dead_size`
- `cogworker_queue_size{queue=…}`
- `cogworker_queue_latency_seconds{queue=…}`
- `cogworker_busy_workers`

To turn the endpoint off, set `Cogworker::Web.prometheus_exporter_enabled = false`.

## Introspection API

```ruby
stats = Cogworker::Stats.new
stats.processed; stats.failed; stats.enqueued
stats.retry_size; stats.scheduled_size; stats.dead_size

q = Cogworker::Queue.new('default')
q.size; q.latency          # latency: age of the oldest job, in seconds
q.each { |job| job.klass; job.args; job.jid }
q.pause!; q.resume!; q.clear

Cogworker::ProcessSet.new.each do |process|
  process['identity']; process['busy']
  process.quiet!           # remotely: stop fetching new jobs
  process.resume!          # remotely: start fetching again
  process.stop!            # remotely: finish running jobs and exit
end

Cogworker::WorkSet.new.each { |identity, thread_id, work| work.job }   # jobs running right now
```

## Testing

```ruby
require 'cogworker'

Cogworker::Testing.fake!   # jobs are collected in memory; Redis isn't touched
GreetingJob.perform_async('bob')
expect(GreetingJob.jobs.size).to eq(1)
expect(GreetingJob.jobs.first['args']).to eq(['bob'])
GreetingJob.perform_one    # run the oldest recorded job (raises Testing::EmptyQueueError if none)
GreetingJob.drain          # run them all, including jobs they enqueue
Cogworker::Testing.drain_all   # the same, for every job class
GreetingJob.clear          # or Cogworker::Testing.clear_jobs!

Cogworker::Testing.inline! do
  GreetingJob.perform_async('bob')  # runs synchronously through the server middleware chain
end

Cogworker::Testing.disable!         # back to real Redis (the default mode)
```

All three methods accept a block: the mode applies only inside the block,
then the previous mode comes back. In `inline!` mode, an exception from
`perform` is raised to the caller, and the `perform_in` delay is ignored.

## Example app

`examples/` contains a working app: jobs, an init file, `cogworker.yml`,
and a `config.ru` that mounts the Web UI. See
[`examples/README.md`](examples/README.md) for how to run it.

## Development

```sh
bundle install
bundle exec rspec     # needs a local Redis at redis://localhost:6379/15 (the db is flushed!)
bundle exec rubocop
```

To use a different test Redis, set `COGWORKER_TEST_REDIS_URL`. The browser
tests (`spec/cogworker/web_system_spec.rb`) need Chrome or Chromium
installed.

CI runs the suite on Ruby 3.1–4.0 against both redis-rb 4.8 and 5.x, via
`gemfiles/redis_4.gemfile` / `gemfiles/redis_5.gemfile`. To reproduce one
combination locally:

```sh
BUNDLE_GEMFILE=gemfiles/redis_4.gemfile bundle install
BUNDLE_GEMFILE=gemfiles/redis_4.gemfile bundle exec rspec
```

`COGWORKER_RELOAD=true` hot-reloads the code (via Zeitwerk) on every Web UI
request. Use it only in development, and only for the web process:

```sh
COGWORKER_RELOAD=true bundle exec rackup ./examples/config.ru -p 9394
```

## License

MIT, see [LICENSE.txt](LICENSE.txt).
