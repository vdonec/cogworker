# frozen_string_literal: true

require 'cgi'
require 'json'

module Cogworker
  class Web
    module Routes
      # Landing tab: the 5 headline counters, a latency-by-queue glance, and
      # the queue list — plus, in "queue first" layout, a per-queue detail
      # pane (own counters + its pending jobs, with delete/delete-all)
      # replacing what used to be a separate `/queues/:name` page. Absorbs
      # the old, standalone `Routes::Queues` tab entirely (see CLAUDE.md's
      # nocturne migration notes) rather than sitting alongside it.
      #
      # `?layout=a` (default, "Metrics first": counters + latency bars +
      # queue table) vs `?layout=b` ("Queue first": a queue sidebar plus the
      # selected queue's own detail) is a plain query param read fresh on
      # every request — same full-page-link pattern `Routes::History`'s
      # status filter already uses, not client-side state. The `.seg`
      # segmented control still renders as a real radio pair (so it gets
      # nocturne's own `:has(input:checked)` styling for free) with a
      # one-line `onchange` navigation, since there's no SPA state to flip
      # instead. Also mounted at bare `/` (the app's landing page) — the
      # old `Routes::Stats` tab used to own that alias; absorbed here along
      # with its "Runs per day" chart and Redis info grid when that tab was
      # retired (its own 6 job-counter cards weren't carried over — this
      # tab already has its own 5-card grid).
      module Overview
        CONTENT_ID = 'overview-content'
        # The Redis info grid lives at the very bottom of the page, below
        # both charts — visually separate from `CONTENT_ID`'s own poll_div,
        # so it needs its own dedicated self-polling fragment rather than
        # being one of the pieces `render_content`/`CONTENT_ID` refreshes
        # together.
        REDIS_CONTENT_ID = 'overview-redis-content'
        # Vendored under assets/ (see CLAUDE.md's "Fully offline" section —
        # served locally, not fetched from a CDN) — shared by both charts
        # below (Chart.js supports multiple independent instances off one
        # loaded script).
        CHART_ASSET = 'assets/chart.umd.min.js'
        CHART_CANVAS_ID = 'overview-throughput-canvas'
        CHART_CONTAINER_HEIGHT_PX = 170
        RUNS_CHART_CANVAS_ID = 'overview-runs-canvas'
        RUNS_CHART_CONTAINER_HEIGHT_PX = 220
        # `INFO` field name => card label, for the Redis section. Pulled
        # from the flat Hash `Cogworker::Stats#redis_info` returns (same
        # field names the `redis` gem always uses, regardless of Redis
        # version) — a field missing from a given server/deployment renders
        # as "n/a" rather than raising.
        REDIS_INFO_FIELDS = {
          'redis_version' => 'Version', 'uptime_in_days' => 'Uptime (days)',
          'connected_clients' => 'Connections', 'used_memory_human' => 'Memory Usage',
          'used_memory_peak_human' => 'Peak Memory Usage'
        }.freeze
        # Period switcher options for the "Runs per day" chart —
        # `params['period']` (a plain query string, read fresh on every
        # request) selects one of these by key. Ordered as displayed,
        # shortest first.
        PERIODS = {
          'week' => { 'label' => 'Week', 'days' => 7 },
          'month' => { 'label' => 'Month', 'days' => 30 },
          '3months' => { 'label' => '3 Months', 'days' => 90 },
          '6months' => { 'label' => '6 Months', 'days' => 182 }
        }.freeze
        DEFAULT_PERIOD = 'month'

        module_function

        def registered(app)
          renderer = lambda do
            layout = params['layout'] == 'b' ? 'b' : 'a'
            period = Overview.resolve_period(params['period'])
            content = Overview.render_content(request.script_name, params)
            if hx_request?
              content
            else
              poll_wrapped = Layout.poll_div(CONTENT_ID, request.script_name,
                                             "overview#{Overview.query_string(params)}", content)
              # Both charts live *outside* this poll_div on purpose: an
              # htmx innerHTML swap destroys a `<canvas>` DOM node outright,
              # and Chart.js doesn't notice its own instance is now pointed
              # at an orphaned element, so it never frees it — one more
              # leaked instance every tick, a real bug once (see CLAUDE.md).
              # Rendered once per full page load here, layout A only
              # (layout B has neither), and kept live by their own
              # independent `fetch` polls instead (`throughput_section`/
              # `runs_section` below).
              page_body = poll_wrapped
              if layout == 'a'
                page_body += Overview.throughput_section(request.script_name)
                page_body += Overview.runs_section(period, request.script_name)
                # The very last thing on the page — its own dedicated
                # self-polling fragment (see REDIS_CONTENT_ID above), not
                # part of CONTENT_ID's own poll_div.
                page_body += Layout.poll_div(REDIS_CONTENT_ID, request.script_name, 'overview/redis',
                                             Overview.redis_section)
              end
              extra_head = layout == 'a' ? Overview.chart_head(request.script_name) : ''
              Layout.wrap('Overview', page_body, script_name: request.script_name, extra_head: extra_head)
            end
          end

          app.get('/', &renderer)
          app.get('/overview', &renderer)

          # The Redis info grid's own self-polling fragment route (see
          # REDIS_CONTENT_ID above) — its own dedicated route, always just
          # the fragment, same pattern as `/workers/summary` below.
          app.get('/overview/redis') { Overview.redis_section }

          # Polled directly by the chart's own inline script
          # (`throughput_section`), not an htmx target — returning just the
          # plotted numbers lets it patch the *existing* Chart.js instance
          # in place (`chart.update()`) instead of tearing down and
          # recreating the `<canvas>`, same idea as `Routes::History`'s
          # `/history/data` for its AG Grid.
          app.get('/overview/throughput_data') do
            [200, { 'content-type' => 'application/json' }, [JSON.generate(Overview.throughput_payload)]]
          end

          app.get('/overview/runs_data') do
            period = Overview.resolve_period(params['period'])
            [200, { 'content-type' => 'application/json' }, [JSON.generate(Overview.runs_per_day_payload(period))]]
          end

          # `raw` is the exact JSON string the job entry was pushed with —
          # same "raw" identity `Routes::Dead`/`Routes::Retries` already key
          # their own per-row delete off — so `Queue#delete` can `LREM` it
          # back out of the list.
          app.post('/overview/:name/delete') do
            name = url_params('name')
            Cogworker::Queue.new(name).delete(params['raw'])
            Overview.respond(self, name)
          end

          app.post('/overview/:name/delete_all') do
            name = url_params('name')
            Cogworker::Queue.new(name).clear
            Overview.respond(self, name)
          end

          app.post('/overview/:name/pause') do
            name = url_params('name')
            Cogworker::Queue.new(name).pause!
            Overview.respond(self, name)
          end

          app.post('/overview/:name/resume') do
            name = url_params('name')
            Cogworker::Queue.new(name).resume!
            Overview.respond(self, name)
          end

          # Same "graduate back onto its queue" move `Routes::Jobs`' own
          # per-entry retry_now makes, just applied to every `cogworker:
          # retry` entry whose `queue` matches this one, one at a time (so
          # the usual `zrem`-wins-or-skip concurrency guard still protects
          # each entry individually against a second click/tab).
          app.post('/overview/:name/retry_all') do
            name = url_params('name')
            Overview.retry_all(name)
            Overview.respond(self, name)
          end
        end

        def retry_all(name)
          entries = Cogworker.config.redis { |c| c.zrange(RedisKeys::RETRY, 0, -1) }
          entries.each do |raw|
            job = JSON.parse(raw)
            next unless job['queue'] == name

            Cogworker.config.redis do |c|
              if c.zrem(RedisKeys::RETRY, raw)
                c.sadd(RedisKeys::QUEUES, job['queue'])
                c.lpush(RedisKeys.queue(job['queue']), raw)
              end
            end
          end
        end

        # After an action, htmx gets the refreshed fragment swapped into
        # #overview-content in place; a plain form submission (no JS) falls
        # back to a normal redirect to that same URL. `action.params
        # ['layout']` — a hidden field every action's own form carries (see
        # `queue_action_button`) — decides whether the response stays on
        # layout A (the queue table a Pause button there was clicked from)
        # or layout B with this queue selected (delete/pause/retry-all
        # triggered from the queue detail pane); it defaults to 'b' since
        # that's the only layout `delete`/`delete_all` have ever been
        # reachable from.
        def respond(action, name)
          layout = action.params['layout'] == 'a' ? 'a' : 'b'
          target = layout == 'a' ? { 'layout' => 'a' } : { 'layout' => 'b', 'queue' => name }
          if action.hx_request?
            render_content(action.request.script_name, target)
          else
            action.redirect(Layout.path(action.request.script_name, "overview#{query_string(target)}"))
          end
        end

        def query_string(params)
          layout = params['layout'] == 'b' ? 'b' : 'a'
          qs = "?layout=#{layout}"
          qs += "&queue=#{CGI.escape(params['queue'])}" if layout == 'b' && params['queue']
          qs
        end

        def render_content(script_name, params)
          layout = params['layout'] == 'b' ? 'b' : 'a'
          body = layout == 'b' ? render_layout_b(script_name, params['queue']) : render_layout_a(script_name)
          <<~HTML
            <div style="display: flex; flex-direction: column; gap: 20px;">
              #{page_header(script_name, layout)}
              #{body}
            </div>
          HTML
        end

        def page_header(script_name, layout)
          a_href = Layout.path(script_name, 'overview?layout=a')
          b_href = Layout.path(script_name, 'overview?layout=b')
          <<~HTML
            <div style="display: flex; align-items: flex-end; justify-content: space-between; gap: 16px; flex-wrap: wrap;">
              <h2 style="margin: 0;">Overview</h2>
              <div style="display: flex; align-items: center; gap: 8px;">
                <span style="font-size: 11px; letter-spacing: 0.08em; text-transform: uppercase; color: var(--color-neutral-500);">Layout</span>
                <div class="seg">
                  <label class="seg-opt"><input type="radio" name="layout" #{'checked' if layout == 'a'} onchange="location.href='#{a_href}'">A · Metrics first</label>
                  <label class="seg-opt"><input type="radio" name="layout" #{'checked' if layout == 'b'} onchange="location.href='#{b_href}'">B · Queue first</label>
                </div>
              </div>
            </div>
          HTML
        end

        def render_layout_a(script_name)
          queues = queue_names.map { |n| Cogworker::Queue.new(n) }
          stat_cards + queue_table(queues, script_name)
        end

        def stat_cards
          stats = Cogworker::Stats.new
          values = [
            ['Processed', stats.processed, 'var(--color-success)'],
            ['Enqueued', stats.enqueued, 'var(--color-accent)'],
            ['Retrying', stats.retry_size, 'var(--color-warning)'],
            ['Failed', stats.failed, 'var(--color-danger)'],
            ['Dead', stats.dead_size, 'var(--color-neutral-300)']
          ]
          cards = values.map do |label, value, color|
            <<~HTML
              <div class="card elev-sm" style="gap: 4px;">
                <span class="card-kicker">#{Layout.h(label)}</span>
                <span style="font-size: 28px; font-family: var(--font-heading); line-height: 1.1; color: #{color};">#{Layout.h(value)}</span>
              </div>
            HTML
          end.join
          %(<div style="display: grid; grid-template-columns: repeat(auto-fit, minmax(160px, 1fr)); gap: 12px;">#{cards}</div>)
        end

        # Rendered at the very bottom of the page (layout A only), below
        # both charts, in its own self-polling fragment (REDIS_CONTENT_ID
        # above) rather than as part of CONTENT_ID's own poll_div — plain
        # text with no chart, so unlike the two chart sections it *could*
        # safely sit inside CONTENT_ID's poll_div, it just doesn't, to keep
        # it pinned below the charts rather than above them.
        def redis_section
          info = Cogworker::Stats.new.redis_info
          cards = REDIS_INFO_FIELDS.map do |field, label|
            <<~HTML
              <div class="card elev-sm" style="gap: 4px;">
                <span class="card-kicker">#{Layout.h(label)}</span>
                <span style="font-size: 22px; font-family: var(--font-heading);">#{Layout.h(info[field] || 'n/a')}</span>
              </div>
            HTML
          end.join
          <<~HTML
            <section style="background: var(--color-surface); border-radius: var(--radius-md); box-shadow: var(--shadow-sm); padding: 16px 18px; display: flex; flex-direction: column; gap: 12px;">
              <h4 style="margin: 0; font-family: var(--font-heading); font-weight: var(--font-heading-weight); font-size: 17px;">Redis</h4>
              <div style="display: grid; grid-template-columns: repeat(auto-fit, minmax(140px, 1fr)); gap: 12px;">#{cards}</div>
            </section>
          HTML
        end

        def chart_head(script_name)
          %(<script src="#{Layout.path(script_name, CHART_ASSET)}"></script>)
        end

        def resolve_period(raw)
          PERIODS.key?(raw) ? raw : DEFAULT_PERIOD
        end

        # `days_count` consecutive UTC calendar-day strings ending today —
        # matches the UTC bucketing `Cogworker::History::Storage.
        # daily_counts` uses, so lookups by day string always line up.
        def day_labels(days_count)
          now = Time.now.utc
          (days_count - 1).downto(0).map { |offset| (now - (offset * 86_400)).strftime('%Y-%m-%d') }
        end

        # Success/failed counts for `period`, keyed exactly as Chart.js
        # wants them — `labels`/`fullDates` line up index-for-index with
        # `success`/`failed`. Shared between the initial render
        # (`runs_section`, baked into the page) and `/overview/runs_data`
        # (what the chart's own poll re-fetches from then on), so the two
        # can never drift apart.
        def runs_per_day_payload(period)
          days_count = PERIODS.fetch(period, PERIODS[DEFAULT_PERIOD])['days']
          counts = Cogworker::History::Storage.daily_counts(days_count)
          days = day_labels(days_count)
          {
            'labels' => days.map { |d| d[5..] },
            'fullDates' => days,
            'success' => days.map { |d| (counts[d] || {})['success'] || 0 },
            'failed' => days.map { |d| (counts[d] || {})['failed'] || 0 }
          }
        end

        def period_switcher(current_period)
          links = PERIODS.map do |key, opts|
            period_link(key, opts['label'], active: key == current_period)
          end.join
          %(<div class="seg">#{links}</div>)
        end

        # Unlike every other filter in this app (History's status filter,
        # Jobs' status/search, Overview's own A/B layout switch), this one
        # deliberately does *not* navigate (`location.href=`) — switching
        # periods only needs to change the Runs-per-day chart's own data,
        # and a full page reload would tear down and rebuild the
        # Throughput chart's `<canvas>`/Chart.js instance right along with
        # it for no reason (the exact zombie-instance hazard the "fully
        # outside any poll_div" comment on `runs_section`/`throughput_
        # section` already guards against for htmx swaps — a full
        # navigation is just as destructive). `window.
        # cogworkerChangeRunsPeriod` (defined in `runs_section` below)
        # fetches the new period's data and patches the *existing* chart
        # instance in place instead.
        def period_link(key, label, active:)
          %(<label class="seg-opt"><input type="radio" name="period" #{'checked' if active} ) +
            %(onchange="window.cogworkerChangeRunsPeriod('#{key}')">#{Layout.h(label)}</label>)
        end

        # A small two-line chart (success/failed per day) rendered by
        # Chart.js (vendored, loaded via `chart_head` — see CLAUDE.md's
        # "Fully offline" section, not fetched from a CDN). Deliberately
        # outside any `Layout.poll_div` (see `registered` above for why):
        # the `<canvas>`/`new Chart(...)` render exactly once per page
        # load, and `refreshRuns` keeps it live afterwards by patching the
        # *existing* instance's data in place, gated by the same `window.
        # cogworkerLiveUpdate` toggle every other tab's poll respects.
        def runs_section(period, script_name)
          payload = runs_per_day_payload(period)
          data_base_url = Layout.path(script_name, 'overview/runs_data')
          <<~HTML
            <section style="background: var(--color-surface); border-radius: var(--radius-md); box-shadow: var(--shadow-sm); padding: 16px 18px;">
              <div style="display: flex; align-items: center; justify-content: space-between; gap: 12px; margin-bottom: 12px; flex-wrap: wrap;">
                <h4 style="margin: 0; font-family: var(--font-heading); font-weight: var(--font-heading-weight); font-size: 17px;">Runs per day</h4>
                #{period_switcher(period)}
              </div>
              <div style="position: relative; height: #{RUNS_CHART_CONTAINER_HEIGHT_PX}px; width: 100%;">
                <canvas id="#{RUNS_CHART_CANVAS_ID}"></canvas>
              </div>
              <script>
                (function () {
                  var dataBaseUrl = #{Layout.json_for_script(data_base_url)};
                  var currentPeriod = #{Layout.json_for_script(period)};
                  var fullDates = #{Layout.json_for_script(payload['fullDates'])};
                  var cssVar = function (name) { return getComputedStyle(document.documentElement).getPropertyValue(name).trim(); };
                  var successColor = cssVar('--color-success');
                  var dangerColor = cssVar('--color-danger');
                  var tickColor = cssVar('--color-neutral-500');
                  var gridColor = cssVar('--color-divider');
                  var chart = new Chart(document.getElementById(#{Layout.json_for_script(RUNS_CHART_CANVAS_ID)}), {
                    type: 'line',
                    data: {
                      labels: #{Layout.json_for_script(payload['labels'])},
                      datasets: [
                        { label: 'Success', data: #{Layout.json_for_script(payload['success'])},
                          borderColor: successColor, backgroundColor: successColor,
                          tension: 0.3, pointRadius: 2, borderWidth: 2 },
                        { label: 'Failed', data: #{Layout.json_for_script(payload['failed'])},
                          borderColor: dangerColor, backgroundColor: dangerColor,
                          tension: 0.3, pointRadius: 2, borderWidth: 2 }
                      ]
                    },
                    options: {
                      responsive: true,
                      maintainAspectRatio: false,
                      interaction: { mode: 'index', intersect: false },
                      scales: {
                        x: { ticks: { color: tickColor, maxRotation: 0, autoSkip: true, maxTicksLimit: 8 }, grid: { display: false } },
                        y: { beginAtZero: true, ticks: { color: tickColor, precision: 0 }, grid: { color: gridColor } }
                      },
                      plugins: {
                        legend: { labels: { color: tickColor } },
                        tooltip: { callbacks: { title: function (items) { return fullDates[items[0].dataIndex]; } } }
                      }
                    }
                  });

                  function applyPeriodData(data) {
                    fullDates = data.fullDates;
                    chart.data.labels = data.labels;
                    chart.data.datasets[0].data = data.success;
                    chart.data.datasets[1].data = data.failed;
                    chart.update();
                  }

                  function fetchPeriod(period) {
                    return fetch(dataBaseUrl + '?period=' + encodeURIComponent(period), { headers: { 'Accept': 'application/json' } })
                      .then(function (r) { return r.ok ? r.json() : null; });
                  }

                  function refreshRuns() {
                    if (!window.cogworkerLiveUpdate) return;
                    fetchPeriod(currentPeriod).then(function (data) { if (data) applyPeriodData(data); }).catch(function () {});
                  }
                  setInterval(refreshRuns, #{Cogworker::Web.live_update_interval * 1000});

                  // Switching periods only needs this chart's own data —
                  // see `Routes::Overview#period_link`'s comment for why
                  // this patches the existing instance in place instead of
                  // navigating (which would also tear down and rebuild the
                  // unrelated Throughput chart). Also syncs the `period`
                  // query param via `replaceState` (no navigation/reload),
                  // so a manual page refresh or shared link still lands on
                  // the period last chosen here.
                  window.cogworkerChangeRunsPeriod = function (period) {
                    currentPeriod = period;
                    fetchPeriod(period).then(function (data) { if (data) applyPeriodData(data); }).catch(function () {});
                    try {
                      var url = new URL(window.location.href);
                      url.searchParams.set('period', period);
                      history.replaceState(null, '', url);
                    } catch (e) {}
                  };
                })();
              </script>
            </section>
          HTML
        end

        # Success/failed counts per hour, keyed exactly as Chart.js wants
        # them — `labels`/`fullDates` line up index-for-index with
        # `processed`/`failed`. Shared between the initial render
        # (`throughput_section`, baked into the page) and `/overview/
        # throughput_data` (what the chart's own poll re-fetches from then
        # on), so the two can never drift apart — same pattern `Routes::
        # Stats#chart_data_payload` already uses for its own chart.
        def throughput_payload
          series = Cogworker::Throughput.series
          {
            'labels' => series.map { |e| e['time'].strftime('%H:%M') },
            'fullDates' => series.map { |e| e['time'].strftime('%Y-%m-%d %H:00 UTC') },
            'processed' => series.map { |e| e['processed'] },
            'failed' => series.map { |e| e['failed'] }
          }
        end

        # Deliberately outside any `Layout.poll_div` — see the long comment
        # in `registered` above for why. The `<canvas>`/`new Chart(...)`
        # render exactly once per full page load; `refreshThroughput`
        # keeps it live afterwards by patching the *existing* instance's
        # data in place, gated by the same `window.cogworkerLiveUpdate`
        # toggle every other tab's poll respects.
        def throughput_section(script_name)
          payload = throughput_payload
          data_url = Layout.path(script_name, 'overview/throughput_data')
          <<~HTML
            <section style="background: var(--color-surface); border-radius: var(--radius-md); box-shadow: var(--shadow-sm); padding: 16px 18px;">
              <div style="display: flex; align-items: baseline; justify-content: space-between; gap: 12px; margin-bottom: 12px;">
                <h4 style="margin: 0; font-family: var(--font-heading); font-weight: var(--font-heading-weight); font-size: 17px;">Throughput</h4>
                <span style="font-size: 12px; color: var(--color-neutral-500);">jobs per hour · 24h</span>
              </div>
              <div style="position: relative; height: #{CHART_CONTAINER_HEIGHT_PX}px; width: 100%;">
                <canvas id="#{CHART_CANVAS_ID}"></canvas>
              </div>
              <script>
                (function () {
                  var dataUrl = #{Layout.json_for_script(data_url)};
                  var fullDates = #{Layout.json_for_script(payload['fullDates'])};
                  // Reads the live nocturne tokens, not a hardcoded hex —
                  // theme-aware (dark/light), and stays in sync with a
                  // retuned ramp (same reasoning as `runs_section` below).
                  var cssVar = function (name) { return getComputedStyle(document.documentElement).getPropertyValue(name).trim(); };
                  var processedColor = cssVar('--color-accent');
                  var failedColor = cssVar('--color-danger');
                  var tickColor = cssVar('--color-neutral-500');
                  var gridColor = cssVar('--color-divider');
                  var chart = new Chart(document.getElementById(#{Layout.json_for_script(CHART_CANVAS_ID)}), {
                    type: 'line',
                    data: {
                      labels: #{Layout.json_for_script(payload['labels'])},
                      datasets: [
                        { label: 'Processed', data: #{Layout.json_for_script(payload['processed'])},
                          borderColor: processedColor, backgroundColor: processedColor,
                          tension: 0.3, pointRadius: 0, borderWidth: 2 },
                        { label: 'Failed', data: #{Layout.json_for_script(payload['failed'])},
                          borderColor: failedColor, backgroundColor: failedColor, borderDash: [4, 4],
                          tension: 0.3, pointRadius: 0, borderWidth: 1.5 }
                      ]
                    },
                    options: {
                      responsive: true,
                      maintainAspectRatio: false,
                      interaction: { mode: 'index', intersect: false },
                      scales: {
                        x: { ticks: { color: tickColor, maxRotation: 0, autoSkip: true, maxTicksLimit: 8 }, grid: { display: false } },
                        y: { beginAtZero: true, ticks: { color: tickColor, precision: 0 }, grid: { color: gridColor } }
                      },
                      plugins: {
                        legend: { labels: { color: tickColor } },
                        tooltip: { callbacks: { title: function (items) { return fullDates[items[0].dataIndex]; } } }
                      }
                    }
                  });

                  function refreshThroughput() {
                    if (!window.cogworkerLiveUpdate) return;
                    fetch(dataUrl, { headers: { 'Accept': 'application/json' } })
                      .then(function (r) { return r.ok ? r.json() : null; })
                      .then(function (data) {
                        if (!data) return;
                        fullDates = data.fullDates;
                        chart.data.labels = data.labels;
                        chart.data.datasets[0].data = data.processed;
                        chart.data.datasets[1].data = data.failed;
                        chart.update();
                      })
                      .catch(function () {});
                  }
                  setInterval(refreshThroughput, #{Cogworker::Web.live_update_interval * 1000});
                })();
              </script>
            </section>
          HTML
        end

        # The "Latency by queue" section used to sit above this table as its
        # own card, but its bars and this table's own Latency column just
        # showed the same number twice in a row — folded the bar into the
        # column itself (`latency_cell` below) instead of dropping it.
        def queue_table(queues, script_name)
          max_latency = queue_max_latency(queues)
          rows = queues.map do |q|
            link = Layout.path(script_name, "overview?layout=b&queue=#{CGI.escape(q.name)}")
            name_cell = %(<a href="#{link}" style="font-weight: var(--font-heading-weight);">#{Layout.h(q.name)}</a>)
            name_cell += " #{Layout.badge('paused', variant: :warning)}" if q.paused?
            [name_cell, q.size, latency_cell(q, max_latency), queue_pause_button(q, script_name, 'a')]
          end
          table = Layout.table(%w[Name Size Latency Actions], rows,
                               empty_message: 'No queues yet — push a job to create one.', wrapped: false)
          <<~HTML
            <section style="background: var(--color-surface); border-radius: var(--radius-md); box-shadow: var(--shadow-sm); padding: 16px 18px; display: flex; flex-direction: column; gap: 12px;">
              <h4 style="margin: 0; font-family: var(--font-heading); font-weight: var(--font-heading-weight); font-size: 17px;">Queues</h4>
              #{table}
            </section>
          HTML
        end

        def queue_max_latency(queues)
          [queues.map(&:latency).max.to_f, 0.001].max
        end

        def latency_cell(queue, max_latency)
          pct = ((queue.latency / max_latency) * 100).round
          <<~HTML
            <div style="display: flex; flex-direction: column; gap: 4px; min-width: 90px;">
              <span style="font-size: 13px;">#{format_latency(queue.latency)}</span>
              <div style="height: 4px; border-radius: 2px; background: var(--color-neutral-800); overflow: hidden;">
                <div style="height: 100%; border-radius: 2px; background: var(--color-accent); width: #{pct}%;"></div>
              </div>
            </div>
          HTML
        end

        # A one-button `<form>` for a queue-scoped action (pause/resume/
        # retry all) — like `Layout.action_button`, but carrying a hidden
        # `layout` field too, so `respond` (above) knows whether to render
        # the response back as layout A (the queue table this may have been
        # clicked from) or layout B (the queue detail pane).
        def queue_action_button(path, label, layout_context, variant:, icon: nil)
          classes = "btn #{Layout::BUTTON_VARIANTS.fetch(variant)}"
          <<~HTML
            <form style="display: inline;" hx-post="#{path}" hx-target="##{CONTENT_ID}" hx-swap="innerHTML" method="post" action="#{path}">
              <input type="hidden" name="layout" value="#{layout_context}">
              <button type="submit" class="#{classes}" style="font-size: 13px; padding: 4px 10px;">#{Layout.icon_tag(icon)}#{Layout.h(label)}</button>
            </form>
          HTML
        end

        def queue_pause_button(queue, script_name, layout_context)
          if queue.paused?
            action = Layout.path(script_name, "overview/#{CGI.escape(queue.name)}/resume")
            queue_action_button(action, 'resume', layout_context, variant: :primary, icon: 'play')
          else
            action = Layout.path(script_name, "overview/#{CGI.escape(queue.name)}/pause")
            queue_action_button(action, 'pause', layout_context, variant: :warning, icon: 'pause')
          end
        end

        # Nothing to bulk-retry when nothing on this queue is retrying.
        def retry_all_button(name, script_name, retrying_count)
          return '' if retrying_count.zero?

          action = Layout.path(script_name, "overview/#{CGI.escape(name)}/retry_all")
          queue_action_button(action, 'retry all', 'b', variant: :primary, icon: 'arrow-clockwise')
        end

        # `selected_name` wins even when it isn't (yet) in the registered
        # `cogworker:queues` set — e.g. right after a job landed on a brand
        # new queue name via a raw Redis write, before anything called
        # `Client.push` for it — same independence the old standalone
        # `/queues/:name` page had from that registry. Only an *absent*
        # `selected_name` falls back to the registry, and only the true
        # empty-registry case shows the empty state.
        def render_layout_b(script_name, selected_name)
          names = queue_names
          selected_name = names.first if (selected_name.nil? || selected_name.empty?) && !names.empty?
          return %(<p class="text-muted">No queues yet — push a job to create one.</p>) if selected_name.nil? || selected_name.empty?

          <<~HTML
            <div style="display: grid; grid-template-columns: minmax(240px, 320px) minmax(0, 1fr); gap: 16px; align-items: start;">
              #{queue_sidebar(names, selected_name, script_name)}
              #{queue_detail(selected_name, script_name)}
            </div>
          HTML
        end

        def queue_sidebar(names, selected_name, script_name)
          max_latency = names.map { |n| Cogworker::Queue.new(n).latency }.max || 0.001
          max_latency = 0.001 if max_latency.zero?
          items = names.map do |n|
            q = Cogworker::Queue.new(n)
            active = n == selected_name
            href = Layout.path(script_name, "overview?layout=b&queue=#{CGI.escape(n)}")
            bg = active ? 'color-mix(in srgb, var(--color-accent) 12%, var(--color-surface))' : 'var(--color-surface)'
            border = active ? 'var(--color-accent)' : 'var(--color-divider)'
            pct = ((q.latency / max_latency) * 100).round
            <<~HTML
              <a href="#{href}" style="text-align: left; padding: 11px 13px; border-radius: var(--radius-md); background: #{bg}; border: 1px solid #{border}; display: flex; flex-direction: column; gap: 6px; color: var(--color-text); text-decoration: none;">
                <span style="display: flex; align-items: center; justify-content: space-between; gap: 8px;">
                  <span class="mono" style="font-size: 14px;">#{Layout.h(n)}</span>
                  #{q.paused? ? Layout.badge('paused', variant: :warning) : ''}
                </span>
                <span style="font-size: 12px; color: var(--color-neutral-400);">#{q.size} enqueued · #{format_latency(q.latency)} latency</span>
                <span style="height: 3px; border-radius: 2px; background: var(--color-neutral-800); overflow: hidden; display: block;">
                  <span style="display: block; height: 100%; background: var(--color-accent); width: #{pct}%;"></span>
                </span>
              </a>
            HTML
          end.join
          %(<aside style="display: flex; flex-direction: column; gap: 6px;">#{items}</aside>)
        end

        # Running/Retrying/Dead are scoped to this one queue by scanning the
        # (global, not per-queue) WorkSet/retry/dead collections and
        # filtering on each entry's own `queue` field — same technique
        # `Routes::History` already uses to bucket its own global ZSET by
        # day. No "Concurrency" figure here (unlike the "Relay" concept
        # mock): Cogworker has no per-queue concurrency limit, only the
        # process-wide thread pool `Manager` draws from, so showing one
        # would be fabricated.
        def queue_detail(name, script_name)
          q = Cogworker::Queue.new(name)
          retrying_count = zset_count_for_queue(RedisKeys::RETRY, name)
          counters = [
            ['Enqueued', q.size, 'var(--color-text)'],
            ['Running', running_count_for_queue(name), 'var(--color-accent)'],
            ['Retrying', retrying_count, 'var(--color-warning)'],
            ['Dead', zset_count_for_queue(RedisKeys::DEAD, name), 'var(--color-neutral-300)']
          ]
          stat_html = counters.map do |label, value, color|
            <<~HTML
              <div style="display: flex; flex-direction: column; gap: 2px;">
                <span class="card-kicker">#{Layout.h(label)}</span>
                <span style="font-size: 22px; font-family: var(--font-heading); color: #{color};">#{Layout.h(value)}</span>
              </div>
            HTML
          end.join
          paused_tag = q.paused? ? " #{Layout.badge('paused', variant: :warning)}" : ''
          header_actions = queue_pause_button(q, script_name, 'b') + retry_all_button(name, script_name,
                                                                                       retrying_count)
          <<~HTML
            <section style="display: flex; flex-direction: column; gap: 16px; min-width: 0;">
              <div style="background: var(--color-surface); border-radius: var(--radius-md); box-shadow: var(--shadow-sm); padding: 18px;">
                <div style="display: flex; align-items: flex-start; justify-content: space-between; gap: 16px; flex-wrap: wrap;">
                  <h3 class="mono" style="margin: 0;">#{Layout.h(name)}#{paused_tag}</h3>
                  <div style="display: flex; gap: 8px;">#{header_actions}</div>
                </div>
                <div style="display: grid; grid-template-columns: repeat(auto-fit, minmax(110px, 1fr)); gap: 12px; margin-top: 12px;">
                  #{stat_html}
                </div>
              </div>
              #{queue_jobs_section(name, script_name)}
            </section>
          HTML
        end

        def queue_jobs_section(name, script_name)
          delete_path = Layout.path(script_name, "overview/#{CGI.escape(name)}/delete")
          rows = Cogworker::Queue.new(name).map do |r|
            [r.jid, Layout.h(r.klass), Layout.h(r.args.to_s),
             Layout.form_button(delete_path, 'raw', r.value, 'delete', hx_target: "##{CONTENT_ID}",
                                                                       variant: :danger)]
          end
          delete_all_button(name, script_name, rows.empty?) +
            Layout.table(%w[JID Class Args Delete], rows, empty_message: 'This queue is empty.')
        end

        # Nothing to bulk-delete once the queue is already empty.
        def delete_all_button(name, script_name, empty)
          return '' if empty

          delete_all_path = Layout.path(script_name, "overview/#{CGI.escape(name)}/delete_all")
          button = Layout.action_button(delete_all_path, 'delete all', hx_target: "##{CONTENT_ID}", variant: :danger)
          %(<div style="margin-bottom: var(--space-3); display: flex; justify-content: flex-end;">#{button}</div>)
        end

        def running_count_for_queue(name)
          Cogworker::WorkSet.new.count { |_identity, _tid, work| work.queue == name }
        end

        def zset_count_for_queue(redis_key, name)
          entries = Cogworker.config.redis { |c| c.zrange(redis_key, 0, -1) }
          entries.count { |raw| JSON.parse(raw)['queue'] == name }
        end

        def queue_names
          Cogworker.config.redis { |c| c.smembers(RedisKeys::QUEUES) }.sort
        end

        def format_latency(seconds)
          return "#{(seconds * 1000).round}ms" if seconds < 1
          return "#{seconds.round(1)}s" if seconds < 60

          "#{(seconds / 60).round(1)}m"
        end
      end
    end
  end
end

Cogworker::Web.register(Cogworker::Web::Routes::Overview)
