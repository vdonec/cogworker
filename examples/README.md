# Cogworker example

A minimal, runnable app showing the pieces this gem provides: worker DSL,
`cogworker_options`, custom middleware, periodic jobs, status tracking, run
history, the CLI, the swarm supervisor, and the Web UI (with a custom
extension tab and a Prometheus `/metrics` endpoint).

Requires a local Redis on `redis://localhost:6379/0` (override with
`COGWORKER_EXAMPLE_REDIS_URL`).

## Jobs

- `jobs/greeting_job.rb` — the simplest possible job.
- `jobs/flaky_job.rb` — `cogworker_options retry:`/a custom option key, plus
  `Cogworker::Status::Worker` progress reporting.
- `jobs/daily_report_job.rb` — a periodic job (registered in `init.rb`, fires
  every 5 minutes here for the sake of not waiting an hour to see it run).
- `jobs/low_priority_job.rb` — `cogworker_options queue: 'low'`, showing a
  job pinned to a queue other than `default`. `cogworker.yml`'s `:queues:`
  already listed `default` (twice, for weight) and `low`; this is what
  actually enqueues onto that second one.

## Run it

```sh
# from the gem root
bundle install

# 1. push some jobs
bundle exec ruby ./examples/push_jobs.rb

# 2a. process them with a single process...
bundle exec exe/cogworker -r ./examples/init.rb -C ./examples/cogworker.yml

# 2b. ...or with a supervised multi-process swarm instead
COGWORKER_COUNT=3 PHASED_RESTART=true bundle exec exe/cogworkerswarm \
  -r ./examples/init.rb -C ./examples/cogworker.yml

# 3. Web UI, in another terminal
bundle exec rackup ./examples/config.ru -p 9394
# -> http://localhost:9394/cogworker  (tabs: Queues/Busy/Retries/Scheduled/Periodic/Dead/History/Stats)
# -> http://localhost:9394/cogworker/metrics  (Prometheus text format)

# 3b. same, but with the Web UI's code hot-reloading on every request —
#     edit a file under lib/cogworker/web/** (or examples/config.ru) and
#     refresh the page, no restart needed:
COGWORKER_RELOAD=true bundle exec rackup ./examples/config.ru -p 9394
```

The Busy/Stats/Queues tabs auto-refresh (htmx polling), and History's own
AG Grid live-refreshes in place, every `Cogworker::Web.live_update_interval`
seconds (default 3; set here in `config.ru`) — a single "Live" toggle in the
header (persisted in your browser) pauses/resumes all of them together. The
quiet/stop/delete/retry-now buttons update the page in place instead of
reloading — but every one of them still works with JS disabled too (falls
back to a normal form POST + redirect). The **Dead** tab's `retry` button
does the same "put it back on its queue for one more attempt" move as
Retries' `retry now` — a job only ends up dead after already exhausting its
retries, so this is a manual, one-off exception to that.

Signals on the worker process(es): `TSTP` = quiet (stop fetching new jobs),
`TERM`/`INT` = graceful stop. On the swarm parent specifically, `USR2`
triggers a phased (one-at-a-time) restart of its children when
`PHASED_RESTART=true`.

Check a job's status from any Ruby console that requires `./init.rb`:

```ruby
Cogworker::Status.status(jid)  # "queued" / "working" / "retrying" / "complete" / "failed"
```

The **Periodic** tab is read-only: it lists every `config.periodic { |mgr|
mgr.register(...) }` entry (cron, class, args, unique mode) along with its
computed next run and its last actual run time — sourced from Redis
(`periodic:schedule`/`periodic:last_slot:<pjid>`), which only gets written
once a real worker process's `Periodic::Ticker` has booted at least once;
running only the Web UI shows an empty state, same as Busy with no worker
running.

## Stress testing

`stress_test.rb` hammers three things under real concurrency: job
throughput (a real `Manager` processing pool), the Web UI (many threads
calling `Cogworker::Web.call` at once, optionally under
`COGWORKER_RELOAD=true`), and `Periodic::Ticker` racing many simulated
processes for the same cron slot. It's a standalone tool, not part of this
demo app — it uses its own Redis db (`COGWORKER_STRESS_REDIS_URL`, default
db 14) so it never touches this app's db 0 or the spec suite's db 15.

```sh
bundle exec ruby ./examples/stress_test.rb all             # all three, sane defaults
bundle exec ruby ./examples/stress_test.rb throughput --jobs=50000 --concurrency=50
bundle exec ruby ./examples/stress_test.rb web --web-threads=64 --reload
bundle exec ruby ./examples/stress_test.rb periodic --tickers=100
bundle exec ruby ./examples/stress_test.rb -h              # every option, with defaults
```

The **History** tab lists every run (success and failure) in an AG Grid
table (sortable/filterable columns, client-side pagination), filterable by
status via the All/Success/Failed links above it, with the job's full args
and — for failures — a click-to-open backtrace dialog. Retention depth is
set in `init.rb`
(`Cogworker::History.configure_server_middleware(config, max_entries: 500)`);
page size is `Cogworker::Web.history_per_page` (default 25).
