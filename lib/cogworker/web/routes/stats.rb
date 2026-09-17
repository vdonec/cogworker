# frozen_string_literal: true

require 'json'

module Cogworker
  class Web
    module Routes
      # The 6 job-counter cards, the "Runs per day" Chart.js graph, and a
      # Redis INFO summary.
      module Stats
        COUNTERS_CONTENT_ID = 'stats-counters-content'
        REDIS_CONTENT_ID = 'stats-redis-content'
        # The 6 job-counter colors are the same ones `Layout.stat_chip` uses
        # for the compact bar shown on every page — one shared mapping
        # (`Layout::JOB_STAT_ACCENTS`) so the two never drift apart.
        CARD_ACCENTS = Layout::JOB_STAT_ACCENTS.merge(
          'Version' => 'text-gray-700 dark:text-gray-300', 'Uptime (days)' => 'text-gray-700 dark:text-gray-300',
          'Connections' => 'text-gray-700 dark:text-gray-300', 'Memory Usage' => 'text-gray-700 dark:text-gray-300',
          'Peak Memory Usage' => 'text-gray-700 dark:text-gray-300'
        ).freeze
        # `INFO` field name => card label. Pulled from the flat Hash
        # `Cogworker::Stats#redis_info` returns (same field names the
        # `redis` gem always uses, regardless of Redis version) — a field
        # missing from a given server/deployment renders as "n/a" rather
        # than raising.
        REDIS_INFO_FIELDS = {
          'redis_version' => 'Version', 'uptime_in_days' => 'Uptime (days)',
          'connected_clients' => 'Connections', 'used_memory_human' => 'Memory Usage',
          'used_memory_peak_human' => 'Peak Memory Usage'
        }.freeze
        # Period switcher options for the "Runs per day" chart —
        # `params['period']` (a plain query string, read fresh on every
        # request; see `registered` below) selects one of these by key.
        # Ordered as displayed, shortest first.
        PERIODS = {
          'week' => { 'label' => 'Week', 'days' => 7 },
          'month' => { 'label' => 'Month', 'days' => 30 },
          '3months' => { 'label' => '3 Months', 'days' => 90 },
          '6months' => { 'label' => '6 Months', 'days' => 182 }
        }.freeze
        DEFAULT_PERIOD = 'month'
        CHART_SUCCESS_COLOR = '#16a34a'
        CHART_FAILED_COLOR = '#dc2626'
        CHART_CANVAS_ID = 'runs-chart-canvas'
        CHART_CONTAINER_HEIGHT_PX = 220
        # Vendored under assets/ (see CLAUDE.md's "Fully offline" section —
        # served locally, not fetched from a CDN), the same way AG_GRID_ASSETS
        # is in `routes/history.rb`.
        CHART_ASSET = 'assets/chart.umd.min.js'

        module_function

        def registered(app)
          renderer = lambda do
            # A plain query param, not htmx state — the period switcher
            # below is a normal `<a href>` (full page reload), exactly like
            # `Routes::History`'s status filter links.
            period = Stats.resolve_period(params['period'])
            body = Stats.page_body(period, request.script_name)
            if hx_request?
              body
            else
              Layout.wrap('Stats', body, script_name: request.script_name, show_stats_bar: false,
                                         extra_head: Stats.chart_head(request.script_name))
            end
          end

          app.get('/', &renderer)
          app.get('/stats', &renderer)

          # Polled by `Layout.stats_bar` (the global counter strip shown
          # under the header on every page, not just here) — always just
          # this small fragment, never a full page.
          app.get('/stats/bar') { Layout.stats_bar_content }

          # The job-counter and Redis grids each poll their own small
          # fragment independently (see `page_body`) — neither depends on
          # `period`, so unlike the chart there's no query string to carry.
          app.get('/stats/counters') { Stats.counters_grid }
          app.get('/stats/redis') { Stats.redis_grid(Cogworker::Stats.new.redis_info) }

          # Polled directly by the chart's own inline script (`chart`,
          # below) via `fetch` — NOT an htmx target, and deliberately not a
          # full HTML fragment: returning just the plotted numbers lets the
          # chart patch its existing Chart.js instance's data in place
          # (`chart.update()`) instead of tearing down and recreating the
          # `<canvas>`/instance on every tick, which is what an htmx
          # innerHTML-swapped fragment would force. Same idea as
          # `Routes::History`'s `/history/data` for its AG Grid.
          app.get('/stats/chart_data') do
            period = Stats.resolve_period(params['period'])
            [200, { 'content-type' => 'application/json' }, [JSON.generate(Stats.chart_data_payload(period))]]
          end
        end

        def resolve_period(raw)
          PERIODS.key?(raw) ? raw : DEFAULT_PERIOD
        end

        def chart_head(script_name)
          %(<script src="#{Layout.path(script_name, CHART_ASSET)}"></script>)
        end

        # The counters and Redis grids are each their own independently
        # htmx-polled fragment (`Layout.poll_div`) — plain, stateless HTML,
        # cheap to fully replace every tick. The "Runs per day" section in
        # between is a normal, *unpolled* part of the page: its own chart
        # keeps itself live via `/stats/chart_data` instead (see
        # `registered` above and `chart` below), so re-rendering this whole
        # method's output on a poll would rebuild widgets that don't need
        # rebuilding — the counters/Redis grids are the only pieces actually
        # meant to be swapped wholesale on every tick.
        def page_body(period, script_name)
          stats = Cogworker::Stats.new
          counters_poll = Layout.poll_div(COUNTERS_CONTENT_ID, script_name, 'stats/counters', counters_grid(stats))
          runs_chart = Layout.section('Runs per day', runs_per_day_section(period, script_name))
          redis_poll = Layout.section('Redis', Layout.poll_div(REDIS_CONTENT_ID, script_name, 'stats/redis',
                                                               redis_grid(stats.redis_info)))
          counters_poll + runs_chart + redis_poll
        end

        def counters_grid(stats = Cogworker::Stats.new)
          values = {
            'Enqueued' => stats.enqueued, 'Processed' => stats.processed, 'Failed' => stats.failed,
            'Retries' => stats.retry_size, 'Scheduled' => stats.scheduled_size, 'Dead' => stats.dead_size
          }
          cards = values.map { |label, value| card(label, value) }.join
          %(<div class="grid grid-cols-2 sm:grid-cols-3 lg:grid-cols-6 gap-4">#{cards}</div>)
        end

        def redis_grid(info)
          cards = REDIS_INFO_FIELDS.map { |field, label| card(label, info[field] || 'n/a') }.join
          %(<div class="grid grid-cols-2 sm:grid-cols-3 lg:grid-cols-5 gap-4">#{cards}</div>)
        end

        def runs_per_day_section(period, script_name)
          period_switcher(script_name, period) + chart_bubble(period, script_name)
        end

        def period_switcher(script_name, current_period)
          links = PERIODS.map do |key, opts|
            period_link(script_name, key, opts['label'], active: key == current_period)
          end.join
          %(<div class="mb-4 flex gap-2">#{links}</div>)
        end

        def period_link(script_name, key, label, active:)
          classes = if active
                      'bg-indigo-600 text-white'
                    else
                      'bg-gray-100 dark:bg-gray-800 text-gray-600 dark:text-gray-300 hover:bg-gray-200 dark:hover:bg-gray-700'
                    end
          href = Layout.path(script_name, "stats?period=#{key}")
          %(<a href="#{href}" class="px-3 py-1 rounded-md text-sm font-medium #{classes}">#{Layout.h(label)}</a>)
        end

        # Wraps the chart in the same "bubble" card look as the job-counter/
        # Redis stat cards (`card`, below).
        def chart_bubble(period, script_name)
          %(<div class="rounded-lg border border-gray-200 dark:border-gray-800 bg-white dark:bg-gray-900 shadow-sm p-4">#{chart(
            period, script_name
          )}</div>)
        end

        # Success/failed counts for `period`, keyed exactly as Chart.js
        # wants them — `labels`/`fullDates` line up index-for-index with
        # `success`/`failed`. Shared between the initial render (`chart`,
        # baked into the page) and `/stats/chart_data` (what the chart's own
        # poll re-fetches from then on), so the two can never drift apart.
        def chart_data_payload(period)
          days_count = PERIODS.fetch(period, PERIODS[DEFAULT_PERIOD])['days']
          # Fully qualified: a bare `History::Storage` from inside
          # `Routes::Stats` would resolve, via lexical nesting, to
          # `Cogworker::Web::Routes::History` first (this module's sibling
          # route file) — the same gotcha `routes/history.rb` itself
          # documents — not to the top-level `Cogworker::History`.
          counts = Cogworker::History::Storage.daily_counts(days_count)
          days = day_labels(days_count)
          {
            'labels' => days.map { |d| d[5..] },
            'fullDates' => days,
            'success' => days.map { |d| (counts[d] || {})['success'] || 0 },
            'failed' => days.map { |d| (counts[d] || {})['failed'] || 0 }
          }
        end

        # A small two-line chart (success/failed per day) rendered by
        # Chart.js (vendored, loaded via `chart_head` — see CLAUDE.md's
        # "Fully offline" section, not fetched from a CDN), not a hand-rolled
        # SVG: a first attempt at a DIY SVG chart used
        # `preserveAspectRatio="none"` to stretch full width, which visibly
        # distorted the plotted lines/points on any card wider than its
        # aspect ratio, and its styling looked noticeably rougher than a
        # maintained charting library's own defaults (real user report on
        # both counts). `responsive: true` + `maintainAspectRatio: false`
        # fills the fixed-height wrapper div at its full width, at any
        # screen size, without distortion — Chart.js sizes its own
        # `<canvas>` (including devicePixelRatio) via `ResizeObserver`.
        #
        # This section is NOT inside any `Layout.poll_div` (see `page_body`
        # above) — the `<canvas>`/`new Chart(...)` below render exactly once
        # per page load. An earlier version instead re-rendered this whole
        # chart (canvas included) on every htmx poll, which meant creating a
        # brand-new Chart.js instance every tick; skipping `.destroy()` on
        # the previous one (easy to miss, since the *canvas* really was
        # gone) leaked one more zombie instance per poll — real, observed
        # root cause of the chart eventually breaking under live updates.
        # Rather than track and destroy instances across swaps, the fix here
        # is to not recreate the widget at all: the chart keeps itself
        # current by polling `/stats/chart_data` on its own (`refreshChart`
        # below, gated by the same `window.cogworkerLiveUpdate` toggle every
        # other tab's poll respects) and patching the *existing* instance's
        # data in place, exactly like `Routes::History`'s AG Grid does via
        # its own `refreshRows`/`/history/data`.
        def chart(period, script_name)
          payload = chart_data_payload(period)
          data_url = Layout.path(script_name, "stats/chart_data?period=#{period}")

          <<~HTML
            <div style="position: relative; height: #{CHART_CONTAINER_HEIGHT_PX}px; width: 100%;">
              <canvas id="#{CHART_CANVAS_ID}"></canvas>
            </div>
            <script>
              (function () {
                var dataUrl = #{Layout.json_for_script(data_url)};
                var fullDates = #{Layout.json_for_script(payload['fullDates'])};
                var chart = new Chart(document.getElementById(#{Layout.json_for_script(CHART_CANVAS_ID)}), {
                  type: 'line',
                  data: {
                    labels: #{Layout.json_for_script(payload['labels'])},
                    datasets: [
                      { label: 'Success', data: #{Layout.json_for_script(payload['success'])},
                        borderColor: #{Layout.json_for_script(CHART_SUCCESS_COLOR)},
                        backgroundColor: #{Layout.json_for_script(CHART_SUCCESS_COLOR)},
                        tension: 0.3, pointRadius: 2, borderWidth: 2 },
                      { label: 'Failed', data: #{Layout.json_for_script(payload['failed'])},
                        borderColor: #{Layout.json_for_script(CHART_FAILED_COLOR)},
                        backgroundColor: #{Layout.json_for_script(CHART_FAILED_COLOR)},
                        tension: 0.3, pointRadius: 2, borderWidth: 2 }
                    ]
                  },
                  options: {
                    responsive: true,
                    maintainAspectRatio: false,
                    interaction: { mode: 'index', intersect: false },
                    scales: {
                      x: { ticks: { color: '#6b7280', maxRotation: 0, autoSkip: true, maxTicksLimit: 8 }, grid: { display: false } },
                      y: { beginAtZero: true, ticks: { color: '#6b7280', precision: 0 }, grid: { color: 'rgba(107, 114, 128, 0.15)' } }
                    },
                    plugins: {
                      legend: { labels: { color: '#6b7280' } },
                      tooltip: { callbacks: { title: function (items) { return fullDates[items[0].dataIndex]; } } }
                    }
                  }
                });

                function refreshChart() {
                  if (!window.cogworkerLiveUpdate) return;
                  fetch(dataUrl, { headers: { 'Accept': 'application/json' } })
                    .then(function (r) { return r.ok ? r.json() : null; })
                    .then(function (data) {
                      if (!data) return;
                      fullDates = data.fullDates;
                      chart.data.labels = data.labels;
                      chart.data.datasets[0].data = data.success;
                      chart.data.datasets[1].data = data.failed;
                      chart.update();
                    })
                    .catch(function () {});
                }
                setInterval(refreshChart, #{Cogworker::Web.live_update_interval * 1000});
              })();
            </script>
          HTML
        end

        # `days_count` consecutive UTC calendar-day strings ending today —
        # matches the UTC bucketing `Storage.daily_counts` uses, so lookups
        # by day string always line up.
        def day_labels(days_count)
          now = Time.now.utc
          (days_count - 1).downto(0).map { |offset| (now - (offset * 86_400)).strftime('%Y-%m-%d') }
        end

        def card(label, value)
          <<~HTML
            <div class="rounded-lg border border-gray-200 dark:border-gray-800 bg-white dark:bg-gray-900 shadow-sm p-4">
              <div class="text-xs font-semibold uppercase tracking-wider text-gray-500 dark:text-gray-400">#{Layout.h(label)}</div>
              <div class="mt-1 text-2xl font-bold #{CARD_ACCENTS.fetch(label, '')}">#{Layout.h(value)}</div>
            </div>
          HTML
        end
      end
    end
  end
end

Cogworker::Web.register(Cogworker::Web::Routes::Stats)
