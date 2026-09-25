# frozen_string_literal: true

require 'spec_helper'
require 'cgi'
require 'rack/mock'
require 'rack/lint'

RSpec.describe Cogworker::Web do
  # Wrapped in Rack::Lint so a spec-violating response (e.g. a capitalized
  # header name — Puma's dev environment runs this same check and 500s on
  # it, but Rack::MockRequest alone would happily let it through) fails
  # here too, not just when someone happens to click around a real server.
  let(:mock) { Rack::MockRequest.new(Rack::Lint.new(Cogworker::Web)) }

  describe Cogworker::Web::Router do
    it 'compiles :name segments into named captures' do
      pattern = described_class.compile('/queues/:name')
      expect(described_class.match(pattern, '/queues/default')).to eq('name' => 'default')
      expect(described_class.match(pattern, '/queues')).to be_nil
    end

    it 'matches the bare root path' do
      pattern = described_class.compile('/')
      expect(described_class.match(pattern, '/')).to eq({})
      expect(described_class.match(pattern, '/queues')).to be_nil
    end
  end

  describe 'extension mechanism' do
    it 'lets an external module register a route via self.registered(app), reachable through Action#request/#params' do
      mod = Module.new do
        def self.registered(app)
          app.get('/ext/:thing') { "thing=#{params['thing']}&q=#{request.params['q']}" }
        end
      end
      described_class.register(mod)

      resp = mock.get('/ext/widget?q=1')
      expect(resp.status).to eq(200)
      expect(resp.body).to eq('thing=widget&q=1')
    end

    it 'supports url_params as an alias for params[key], matching real extension usage' do
      mod = Module.new do
        def self.registered(app)
          app.get('/ext2') { url_params('x') }
        end
      end
      described_class.register(mod)

      expect(mock.get('/ext2?x=42').body).to eq('42')
    end

    it 'accepts both a raw ERB string and a built-in Symbol template in #erb' do
      mod = Module.new do
        def self.registered(app)
          app.get('/ext3/raw') { erb('hello <%= name %>', locals: { name: 'world' }) }
        end
      end
      described_class.register(mod)

      expect(mock.get('/ext3/raw').body).to eq('hello world')
    end

    it 'exposes Web.tabs as a plain mutable Hash' do
      described_class.tabs['Custom'] = 'ext'
      expect(described_class.tabs['Custom']).to eq('ext')
    end

    it 'register(mod, name:, tab:, index:) accepts the keyword form without raising, and auto-fills tabs when given' do
      mod = Module.new { def self.registered(_app); end }
      described_class.register(mod, name: 'my_ext', tab: 'MyTab', index: 'my_ext_path')
      expect(described_class.tabs['MyTab']).to eq('my_ext_path')
    end
  end

  describe 'safe_request?' do
    it 'allows safe HTTP methods by default' do
      expect(mock.get('/').status).to eq(200)
    end

    it 'matches the root route when mounted without a trailing slash (Rack::URLMap sets PATH_INFO to "")' do
      resp = described_class.call(Rack::MockRequest.env_for('/', 'PATH_INFO' => '', 'SCRIPT_NAME' => '/cogworker'))
      expect(resp[0]).to eq(200)
    end

    it 'blocks a cross-site POST by default (no Sec-Fetch-Site: same-origin)' do
      resp = mock.post('/workers/quiet', params: { 'identity' => 'x' })
      expect(resp.status).to eq(403)
    end

    it 'allows a POST carrying Sec-Fetch-Site: same-origin' do
      resp = mock.post('/workers/quiet', 'HTTP_SEC_FETCH_SITE' => 'same-origin', params: { 'identity' => 'x' })
      expect(resp.status).to eq(302)
    end

    it 'can be reopened to carve out a specific bypass, exactly like a real external auth wrapper would' do
      original = described_class.method(:safe_request?)
      begin
        described_class.define_singleton_method(:safe_request?) do |env|
          return true if env['PATH_INFO'] == '/save_session' && env['REQUEST_METHOD'] == 'POST'

          original.call(env)
        end

        resp = mock.post('/save_session')
        expect(resp.status).to eq(200)
      ensure
        described_class.define_singleton_method(:safe_request?, original)
      end
    end
  end

  describe 'timestamps (Layout.time_tag)' do
    around do |example|
      original = Cogworker::Web.time_format
      example.run
      Cogworker::Web.time_format = original
    end

    it 'renders a datetime= attribute (UTC, for the browser-side JS to convert) and a UTC fallback in the configured format' do
      Cogworker::Web.time_format = '%Y-%m-%d %H:%M:%S'
      raw = JSON.generate('jid' => 'x', 'class' => 'X', 'args' => [], 'queue' => 'default')
      Cogworker.config.redis { |c| c.zadd('cogworker:schedule', Time.utc(2026, 1, 2, 3, 4, 5).to_f, raw) }

      body = mock.get('/jobs?status=Scheduled').body
      expect(body).to include('datetime="2026-01-02T03:04:05Z"')
      expect(body).to include('data-cw-time')
      expect(body).to include('>2026-01-02 03:04:05<')
    end

    it 'reflects a custom Web.time_format in the server-rendered fallback' do
      Cogworker::Web.time_format = '%d.%m.%Y'
      raw = JSON.generate('jid' => 'y', 'class' => 'X', 'args' => [], 'queue' => 'default')
      Cogworker.config.redis { |c| c.zadd('cogworker:dead', Time.utc(2026, 1, 2, 3, 4, 5).to_f, raw) }

      body = mock.get('/jobs?status=Dead').body
      expect(body).to include('>02.01.2026<')
    end

    it 'exposes the configured format to the client script as window.COGWORKER_TIME_FORMAT' do
      Cogworker::Web.time_format = '%H:%M'
      body = mock.get('/').body
      expect(body).to include('window.COGWORKER_TIME_FORMAT = "%H:%M"')
    end
  end

  describe 'History tab' do
    around do |example|
      original_per_page = Cogworker::Web.history_per_page
      original_interval = Cogworker::Web.live_update_interval
      example.run
      Cogworker::Web.history_per_page = original_per_page
      Cogworker::Web.live_update_interval = original_interval
    end

    def seed_entry(status, jid:, klass: 'HJob', args: [1], finished_at: 2.0,
                   error_class: nil, error_message: nil, backtrace: %w[line1 line2])
      entry = { 'jid' => jid, 'class' => klass, 'queue' => 'default', 'args' => args,
                'status' => status, 'started_at' => 1.0, 'finished_at' => finished_at }
      if error_class
        entry['error_class'] = error_class
        entry['error_message'] = error_message
        entry['backtrace'] = backtrace
      end
      raw = JSON.generate(entry)
      Cogworker.config.redis do |c|
        c.zadd('cogworker:history:all', entry['finished_at'], raw)
        c.zadd("cogworker:history:#{status}", entry['finished_at'], raw)
      end
    end

    def data(query = '')
      JSON.parse(mock.get("/history/data#{query}").body)
    end

    it 'renders the AG Grid shell (Infinite Row Model) without embedding any row data in the page itself' do
      seed_entry('success', jid: 'ok1', args: [1, 'two'])
      seed_entry('failed', jid: 'bad1', error_class: 'RuntimeError', error_message: 'kaboom')

      body = mock.get('/history').body
      expect(body).to include('ag-grid-community')
      expect(body).to include('id="history-grid"')
      expect(body).to include('id="history-backtrace-dialog"')
      expect(body).to include("rowModelType: 'infinite'")
      expect(body).not_to include('"jid":"ok1"') # rows come from /history/data, block by block
      expect(body).not_to include('kaboom')
    end

    it 'configures the page size (and the matching fetch block size) from Web.history_per_page' do
      Cogworker::Web.history_per_page = 2
      body = mock.get('/history').body
      expect(body).to include('paginationPageSize: 2')
      expect(body).to include('cacheBlockSize: 2')
      # A 1-block cache: the live poll's refreshInfiniteCache() re-fetches
      # every cached block, so anything bigger means one extra request per
      # page visited, on every tick.
      expect(body).to include('maxBlocksInCache: 1')
    end
    it 'embeds a data URL the grid polls for live updates, gated by the same live-update toggle' do
      body = mock.get('/history').body
      expect(body).to include('var dataUrl = "\\/history\\/data?status=all"') # '/' escaped per Layout.json_for_script
      expect(body).to include('if (!window.cogworkerLiveUpdate) return;')
      expect(body).to include('setInterval(refreshRows, 3000);') # default Web.live_update_interval (3s), in ms
    end

    it 'derives the grid refresh interval from Web.live_update_interval, not a hardcoded value' do
      Cogworker::Web.live_update_interval = 7

      body = mock.get('/history').body
      expect(body).to include('setInterval(refreshRows, 7000);')
    end

    it 'renders a page header with a title, and the All/Success/Failed filter pushed to the right of it' do
      body = mock.get('/history').body
      expect(body).to include('<h2 style="margin: 0;">History</h2>')
      expect(body).to include('justify-content: space-between')
      # The heading comes first in source order, matching its position on
      # the left — the filter (right-aligned via the row's own space-
      # between) comes after it, not before.
      expect(body.index('<h2 style="margin: 0;">History</h2>')).to be < body.index('class="seg"')
    end

    describe 'GET /history/data (the grid\'s server-side datasource)' do
      it 'returns one block of rows plus the total, newest first, with full args + backtrace' do
        seed_entry('success', jid: 'ok1', args: [1, 'two'], finished_at: 3.0)
        seed_entry('failed', jid: 'bad1', error_class: 'RuntimeError', error_message: 'kaboom', finished_at: 2.0)

        resp = mock.get('/history/data?start=0&end=50')
        expect(resp.headers['content-type']).to eq('application/json')
        parsed = JSON.parse(resp.body)
        expect(parsed['total']).to eq(2)
        expect(parsed['rows'].map { |e| e['jid'] }).to eq(%w[ok1 bad1])
        expect(parsed['rows'][0]['args']).to eq([1, 'two'])
        expect(parsed['rows'][1]['backtrace']).to eq(%w[line1 line2])
      end

      it 'pages server-side: only the requested start/end slice is returned, total stays the full count' do
        5.times { |i| seed_entry('success', jid: "j#{i}", finished_at: 10.0 + i) }

        page2 = data('?start=2&end=4')
        expect(page2['total']).to eq(5)
        expect(page2['rows'].map { |e| e['jid'] }).to eq(%w[j2 j1])
      end

      it 'honors the status filter (a different ZSET), with its own total' do
        seed_entry('success', jid: 'ok1')
        seed_entry('failed', jid: 'bad1')

        failed_only = data('?status=failed&start=0&end=50')
        expect(failed_only['rows'].map { |e| e['jid'] }).to eq(['bad1'])
        expect(failed_only['total']).to eq(1)
      end

      it "sorts server-side by the grid's sortModel, including computed columns like Duration" do
        seed_entry('success', jid: 'slow', finished_at: 9.0)  # started_at 1.0 → 8000ms
        seed_entry('success', jid: 'fast', finished_at: 1.5)  # 500ms
        seed_entry('success', jid: 'mid', finished_at: 3.0)   # 2000ms

        asc = data("?start=0&end=50&sort=#{CGI.escape('[{"colId":"duration","sort":"asc"}]')}")
        expect(asc['rows'].map { |e| e['jid'] }).to eq(%w[fast mid slow])

        oldest_first = data("?start=0&end=50&sort=#{CGI.escape('[{"colId":"finished_at","sort":"asc"}]')}")
        expect(oldest_first['rows'].map { |e| e['jid'] }).to eq(%w[fast mid slow])
      end

      it "filters server-side by the grid's filterModel, total reflecting the filtered count" do
        seed_entry('success', jid: 'a1', klass: 'MailerJob', finished_at: 3.0)
        seed_entry('failed', jid: 'a2', klass: 'ReportJob', finished_at: 2.0,
                             error_class: 'Timeout::Error', error_message: 'too slow')
        seed_entry('success', jid: 'a3', klass: 'mailer_cleanup', finished_at: 1.5)

        by_class = { 'class' => { 'filterType' => 'text', 'type' => 'contains', 'filter' => 'MAILER' } }
        resp = data("?start=0&end=1&filter=#{CGI.escape(JSON.generate(by_class))}")
        expect(resp['total']).to eq(2) # case-insensitive, like AG Grid's own text filter
        expect(resp['rows'].map { |e| e['jid'] }).to eq(['a1'])

        by_error = { 'error' => { 'filterType' => 'text', 'type' => 'startsWith', 'filter' => 'timeout::' } }
        expect(data("?start=0&end=50&filter=#{CGI.escape(JSON.generate(by_error))}")['rows'].map { |e| e['jid'] })
          .to eq(['a2'])

        slow = { 'duration' => { 'filterType' => 'number', 'type' => 'greaterThan', 'filter' => 600 } }
        expect(data("?start=0&end=50&filter=#{CGI.escape(JSON.generate(slow))}")['rows'].map { |e| e['jid'] })
          .to contain_exactly('a1', 'a2')

        either = { 'class' => { 'filterType' => 'text', 'operator' => 'OR', 'conditions' => [
          { 'filterType' => 'text', 'type' => 'equals', 'filter' => 'reportjob' },
          { 'filterType' => 'text', 'type' => 'endsWith', 'filter' => 'cleanup' }
        ] } }
        expect(data("?start=0&end=50&filter=#{CGI.escape(JSON.generate(either))}")['rows'].map { |e| e['jid'] })
          .to eq(%w[a2 a3])
      end

      it 'treats a malformed sort/filter param as none rather than erroring' do
        seed_entry('success', jid: 'ok1')

        resp = mock.get('/history/data?start=0&end=50&sort=not-json&filter=%5B1%5D')
        expect(resp.status).to eq(200)
        expect(JSON.parse(resp.body)['rows'].map { |e| e['jid'] }).to eq(['ok1'])
      end

      it 'caps a single block at HistoryQuery::MAX_LIMIT rows, whatever end= asks for' do
        stub_const('Cogworker::Web::HistoryQuery::MAX_LIMIT', 2)
        3.times { |i| seed_entry('success', jid: "c#{i}", finished_at: 10.0 + i) }

        expect(data('?start=0&end=100000')['rows'].size).to eq(2)
      end
    end
  end

  describe 'built-in tabs' do
    it 'Overview renders a Redis section (version, uptime, connections, memory usage) from a real INFO call' do
      resp = mock.get('/overview')
      expect(resp.status).to eq(200)
      expect(resp.body).to include('Redis')
      expect(resp.body).to include('Version')
      expect(resp.body).to include('Uptime (days)')
      expect(resp.body).to include('Connections')
      expect(resp.body).to include('Memory Usage')
      expect(resp.body).to include('Peak Memory Usage')
      # A real value from the real local Redis this suite runs against —
      # not a mock — proves this actually calls INFO rather than faking it.
      real_version = Cogworker.config.redis { |c| c.info['redis_version'] }
      expect(resp.body).to include(real_version)
    end

    it 'Overview renders the Redis section at the very bottom of the page, below both charts, in its own ' \
       'self-polling fragment (not inside the main CONTENT_ID poll_div, and not inside the charts)' do
      body = mock.get('/overview').body
      content_start = body.index("id=\"#{Cogworker::Web::Routes::Overview::CONTENT_ID}\"")
      redis_content_start = body.index("id=\"#{Cogworker::Web::Routes::Overview::REDIS_CONTENT_ID}\"")
      runs_start = body.index('overview-runs-canvas')
      expect(content_start).to be < redis_content_start
      expect(runs_start).to be < redis_content_start
    end

    it 'GET /overview/redis returns just the Redis fragment (no page chrome), polled independently of ' \
       "CONTENT_ID's own poll_div" do
      resp = mock.get('/overview/redis')
      expect(resp.status).to eq(200)
      expect(resp.body).not_to include('<html>')
      expect(resp.body).to include('Redis')
      expect(resp.body).to include('Version')
    end

    it "Cogworker::Stats#redis_info exposes the full INFO reply, and missing fields render as 'n/a' on Overview" do
      stats = Cogworker::Stats.new
      expect(stats.redis_info).to be_a(Hash)
      expect(stats.redis_info['redis_version']).to be_a(String)

      allow(Cogworker::Stats).to receive(:new).and_wrap_original do |orig, *args|
        orig.call(*args).tap { |s| allow(s).to receive(:redis_info).and_return({}) }
      end
      expect(mock.get('/overview').body).to include('n/a')
    end

    it 'bare / is an alias for /overview — the old Stats tab used to own that landing-page role' do
      expect(mock.get('/').body).to include('Overview')
      expect(mock.get('/').body).to include('Redis')
    end

    it 'Overview renders a per-day success/failed Runs-per-day chart, using real History entries' do
      # Via `Storage.record` (not a raw `zadd`) — "Runs per day" reads its
      # own daily counter (see `Storage.daily_counts`'s comment), which only
      # `record` itself keeps updated, not a direct write to the
      # `cogworker:history:*` ZSETs.
      Cogworker::History::Storage.record({ 'jid' => 'chartok', 'class' => 'ChartOkJob', 'args' => [] }, 'default',
                                         Time.now.to_f, Time.now.to_f, 'success')
      Cogworker::History::Storage.record({ 'jid' => 'chartbad', 'class' => 'ChartBadJob', 'args' => [] }, 'default',
                                         Time.now.to_f, Time.now.to_f, 'failed')

      body = mock.get('/overview').body
      expect(body).to include('Runs per day')
      today_str = Time.now.utc.strftime('%Y-%m-%d')
      expect(body).to include(today_str) # embedded in the chart's `fullDates` tooltip-title array
      # Default period is Month (30 days): every day is 0/0 except today,
      # which has exactly 1 success and 1 failed.
      expect(body).to include((Array.new(29, 0) + [1]).to_json)
    end

    it 'Overview renders the Runs-per-day chart via the vendored Chart.js (not a CDN), inside its own ' \
       'bordered card, in addition to its own Throughput chart' do
      body = mock.get('/overview').body
      expect(body).to include('src="/assets/chart.umd.min.js"')
      expect(body).to match(%r{background: var\(--color-surface\);.*>Runs per day<.*<div style="position: relative;.*<canvas id="overview-runs-canvas"></canvas>}m)
      expect(body.scan('new Chart(').size).to eq(2) # Throughput + Runs per day, two independent instances
      expect(body).not_to match(%r{https?://}) # vendored, not fetched from jsdelivr/unpkg/etc
    end

    it "neither of Overview's two charts sits inside its own self-polling container — regression test " \
       'for a real leak: an earlier version re-rendered a chart (canvas included) on every htmx poll, ' \
       'creating a new, never-destroyed Chart.js instance each tick, eventually breaking it under live ' \
       'updates (the fix that was already applied to the old Stats tab, carried over here)' do
      body = mock.get('/overview').body
      content_start = body.index("id=\"#{Cogworker::Web::Routes::Overview::CONTENT_ID}\"")
      throughput_start = body.index('overview-throughput-canvas')
      runs_start = body.index('overview-runs-canvas')
      expect(content_start).to be < throughput_start
      expect(content_start).to be < runs_start
      # Both keep themselves live by re-fetching their own small JSON
      # endpoint and patching the *existing* instance's data in place —
      # never recreating it, so there's nothing to leak.
      expect(body).to include('fetch(dataUrl') # Throughput's own poll
      expect(body).to include('fetch(dataBaseUrl') # Runs-per-day's own poll/period-switch fetch
      expect(body.scan('chart.update()').size).to eq(2)
    end

    it 'GET /overview/runs_data returns just the plotted numbers as JSON, honoring ?period=' do
      Cogworker::History::Storage.record({ 'jid' => 'apiok', 'class' => 'ApiOkJob', 'args' => [] }, 'default',
                                         Time.now.to_f, Time.now.to_f, 'success')

      resp = mock.get('/overview/runs_data?period=week')
      expect(resp.headers['content-type']).to eq('application/json')
      payload = JSON.parse(resp.body)
      expect(payload['labels'].size).to eq(7)
      expect(payload['fullDates'].last).to eq(Time.now.utc.strftime('%Y-%m-%d'))
      expect(payload['success'].last).to eq(1)
      expect(payload['failed'].last).to eq(0)
    end

    describe 'Overview Runs-per-day period switcher (week/month/3 months/6 months)' do
      # A `.seg` segmented control of real radio inputs (so it gets
      # nocturne's own `:has(input:checked)` active styling for free — see
      # the layout A/B switcher, the same pattern), each calling
      # `window.cogworkerChangeRunsPeriod` on `onchange` rather than
      # navigating (`location.href=`) — switching periods only needs to
      # patch the Runs-per-day chart's own data in place; a full page
      # reload would needlessly tear down and rebuild the unrelated
      # Throughput chart's Chart.js instance too. "Which one is active" is
      # the `checked` attribute, not a CSS class on the link.
      def period_option(body, key)
        body[/<label class="seg-opt"><input type="radio" name="period"[^>]*onchange="window\.cogworkerChangeRunsPeriod\('#{key}'\)"[^>]*>/]
      end

      it 'renders all 4 options as radio labels, defaulting to Month' do
        body = mock.get('/overview').body
        %w[Week Month].each { |label| expect(body).to include(">#{label}<") }
        expect(body).to include('>3 Months<')
        expect(body).to include('>6 Months<')
        expect(period_option(body, 'week')).not_to be_nil
        expect(period_option(body, 'month')).to include('checked')
        expect(period_option(body, '3months')).not_to be_nil
        expect(period_option(body, '6months')).not_to be_nil
      end

      it 'highlights whichever period is selected via ?period=' do
        body = mock.get('/overview?period=6months').body
        expect(period_option(body, '6months')).to include('checked')
        expect(period_option(body, 'month')).not_to include('checked')
      end

      it 'falls back to the default period for an unrecognized ?period value' do
        body = mock.get('/overview?period=bogus').body
        expect(period_option(body, 'month')).to include('checked')
      end

      it 'a shorter period drops entries outside its window, a longer one still includes them' do
        old_day = Time.now.utc - (20 * 86_400) # within month/3months/6months, outside week
        raw = JSON.generate('jid' => 'oldrun', 'class' => 'OldRunJob', 'queue' => 'default', 'args' => [],
                            'status' => 'success', 'started_at' => old_day.to_f, 'finished_at' => old_day.to_f)
        Cogworker.config.redis do |c|
          c.zadd('cogworker:history:all', old_day.to_f, raw)
          c.zadd('cogworker:history:success', old_day.to_f, raw)
        end
        old_day_str = old_day.strftime('%Y-%m-%d')

        expect(mock.get('/overview?period=month').body).to include(old_day_str) # in fullDates for a 30-day window
        expect(mock.get('/overview?period=week').body).not_to include(old_day_str) # outside a 7-day window
      end

      it 'the initial period is baked in as a plain JS variable the chart\'s own poll and the period-switch ' \
         'handler both read/update, not into the data URL itself (which never carries ?period= — the ' \
         'period is always sent as a fetch param instead, so switching periods never has to touch the URL ' \
         'string the periodic poll re-uses)' do
        body = mock.get('/overview?period=week').body
        expect(body).to include('var dataBaseUrl = "\\/overview\\/runs_data"') # '/' escaped per Layout.json_for_script
        expect(body).to include('var currentPeriod = "week"')
      end
    end

    it 'Overview lists a queue (layout A) and its jobs (layout B)' do
      stub_const('WebQueueJob', Class.new { include Cogworker::Worker })
      WebQueueJob.perform_async(1, 2)

      list = mock.get('/overview')
      expect(list.body).to include('default')

      detail = mock.get('/overview?layout=b&queue=default')
      expect(detail.body).to include('WebQueueJob')
    end

    it "Overview's queue table renders latency as a value plus its own mini-bar, no separate " \
       '"Latency by queue" section (folded in, rather than showing the same number twice on the page)' do
      stub_const('WebLatencyJob', Class.new { include Cogworker::Worker })
      WebLatencyJob.perform_async

      body = mock.get('/overview').body
      expect(body).not_to include('Latency by queue')
      expect(body).to include('>Queues<') # the table's own heading — merging the section didn't drop it
      expect(body).to include('>Latency<') # still a table column header
      # The bar itself — same small accent-filled-bar markup the old
      # standalone section used, just now inside the table's Latency cell.
      expect(body).to match(%r{background: var\(--color-accent\); width: \d+%;"></div>})
    end

    it 'Overview layout A renders the Throughput chart (vendored Chart.js, not a CDN); layout B has none' do
      body = mock.get('/overview').body
      expect(body).to include('src="/assets/chart.umd.min.js"')
      expect(body).to include('id="overview-throughput-canvas"')
      expect(body).to include('new Chart(')
      expect(body).not_to match(%r{https?://}) # vendored, not fetched from a CDN

      body_b = mock.get('/overview?layout=b').body
      expect(body_b).not_to include('overview-throughput-canvas')
      expect(body_b).not_to include('chart.umd.min.js')
    end

    it "the Throughput chart sits outside Overview's own self-polling container — regression test for " \
       'the same Chart.js-instance-leak class of bug already fixed on Stats: an htmx innerHTML swap would ' \
       'destroy the <canvas> DOM node on every tick without ever freeing the old Chart.js instance' do
      resp = mock.get('/overview', 'HTTP_HX_REQUEST' => 'true')
      expect(resp.body).not_to include('overview-throughput-canvas')

      full_page = mock.get('/overview').body
      expect(full_page).to include('id="overview-content"')
      # The chart section must render *after* the poll_div wrapper starts,
      # as a sibling following it — not nested inside the fragment that
      # gets replaced wholesale on every tick (confirmed above).
      poll_div_start = full_page.index('id="overview-content"')
      chart_start = full_page.index('overview-throughput-canvas')
      expect(chart_start).to be > poll_div_start
    end

    it 'GET /overview/throughput_data returns the same 24-hour series Cogworker::Throughput.series computes' do
      Cogworker::Throughput.record('processed')

      resp = mock.get('/overview/throughput_data')
      expect(resp.headers['content-type']).to eq('application/json')
      payload = JSON.parse(resp.body)
      expect(payload['labels'].size).to eq(24)
      expect(payload['processed'].last).to eq(1)
      expect(payload['failed'].last).to eq(0)
    end

    it 'Jobs lists Dead entries newest DiedAt first' do
      older = JSON.generate('jid' => 'older', 'class' => 'OlderDeadJob', 'args' => [], 'queue' => 'default')
      newer = JSON.generate('jid' => 'newer', 'class' => 'NewerDeadJob', 'args' => [], 'queue' => 'default')
      Cogworker.config.redis do |c|
        c.zadd('cogworker:dead', Time.now.to_f - 3600, older)
        c.zadd('cogworker:dead', Time.now.to_f, newer)
      end

      body = mock.get('/jobs?status=Dead').body
      expect(body.index('NewerDeadJob')).to be < body.index('OlderDeadJob')
    end

    it "Jobs' retry now/retry/delete actions carry a Phosphor icon (row actions double as the detail " \
       "panel's own, so both get one — the mock only skips icons on plain per-row buttons)" do
      raw = JSON.generate('jid' => 'iconjid', 'class' => 'IconRetryJob', 'args' => [], 'queue' => 'default',
                          'error_class' => 'RuntimeError', 'error_message' => 'boom')
      Cogworker.config.redis { |c| c.zadd('cogworker:retry', Time.now.to_f, raw) }

      body = mock.get('/jobs?status=Retrying').body
      expect(body).to include('<i class="ph ph-arrow-clockwise"></i>retry now')
      expect(body).to include('<i class="ph ph-trash"></i>delete')
    end

    it "Jobs' detail panel offers Reschedule for a Retrying entry, not for a Dead one" do
      raw = JSON.generate('jid' => 'reschedjid', 'class' => 'ReschedJob', 'args' => [], 'queue' => 'default')
      Cogworker.config.redis { |c| c.zadd('cogworker:retry', Time.now.to_f + 60, raw) }
      raw_dead = JSON.generate('jid' => 'deadjid2', 'class' => 'DeadJob2', 'args' => [], 'queue' => 'default')
      Cogworker.config.redis { |c| c.zadd('cogworker:dead', Time.now.to_f, raw_dead) }

      body = mock.get('/jobs?status=Retrying&selected=reschedjid').body
      expect(body).to include('Reschedule')
      expect(body).to include('name="minutes"')

      body = mock.get('/jobs?status=Dead&selected=deadjid2').body
      expect(body).not_to include('Reschedule')
    end

    it "Jobs' detail panel caps its Retry history, linking to History for the rest — not the full, " \
       'possibly much longer, stored trail' do
      limit = Cogworker::Web::Routes::Jobs::ATTEMPTS_DISPLAY_LIMIT
      raw = JSON.generate('jid' => 'manyretryjid', 'class' => 'ManyRetryJob', 'args' => [], 'queue' => 'default')
      Cogworker.config.redis { |c| c.zadd('cogworker:retry', Time.now.to_f + 60, raw) }
      total_attempts = limit + 3
      total_attempts.times do |i|
        Cogworker::Attempts.record('manyretryjid', attempt: i + 1,
                                                   error: RuntimeError.new("boom #{i}"), outcome: 'retrying')
      end

      body = mock.get('/jobs?status=Retrying&selected=manyretryjid').body
      expect(body.scan('Attempt ').size).to eq(limit)
      expect(body).to include("last #{limit} of #{total_attempts}")
      # The newest attempts, not the oldest — `Attempts.for` is oldest-first,
      # reversed for display, so the last `shown` by attempt number should
      # be what's actually on the page.
      expect(body).to include("boom #{total_attempts - 1}") # newest attempt's error
      expect(body).not_to include('boom 0') # oldest attempt's error, trimmed from view
      expect(body).to include('>view in History</a>')
      expect(body).to include('href="/history?jid=manyretryjid"')
    end

    it "History's ?jid= filter narrows the grid to just that job's own runs (success included), across " \
       'every retry attempt, and offers a link back to the unfiltered view' do
      raw_ok = JSON.generate('jid' => 'trackedjid', 'class' => 'TrackedJob', 'queue' => 'default', 'args' => [],
                             'status' => 'success', 'started_at' => 1.0, 'finished_at' => 2.0)
      raw_other = JSON.generate('jid' => 'otherjid', 'class' => 'OtherJob', 'queue' => 'default', 'args' => [],
                                'status' => 'success', 'started_at' => 1.0, 'finished_at' => 2.0)
      Cogworker.config.redis do |c|
        c.zadd('cogworker:history:all', 2.0, raw_ok)
        c.zadd('cogworker:history:success', 2.0, raw_ok)
        c.zadd('cogworker:history:all', 2.0, raw_other)
        c.zadd('cogworker:history:success', 2.0, raw_other)
      end

      body = mock.get('/history?jid=trackedjid').body
      expect(body).to include('Filtered to job')
      expect(body).to include('var dataUrl = "\\/history\\/data?status=all&jid=trackedjid"')
      expect(body).to include('trackedjid')
      expect(body).to include('href="/history?status=all"') # clears the filter, keeps the status

      resp = mock.get('/history/data?jid=trackedjid&start=0&end=50')
      parsed = JSON.parse(resp.body)
      expect(parsed['rows'].map { |e| e['jid'] }).to eq(['trackedjid'])
      expect(parsed['total']).to eq(1)
    end

    it 'generates nav links and form actions prefixed with the actual mount point, not root-absolute' do
      stub_const('WebMountJob', Class.new { include Cogworker::Worker })
      WebMountJob.perform_async

      env = Rack::MockRequest.env_for('/overview', 'SCRIPT_NAME' => '/cogworker', 'PATH_INFO' => '/overview')
      status, _headers, body = Cogworker::Web.call(env)
      html = body.reduce(:+)

      expect(status).to eq(200)
      expect(html).to include('href="/cogworker/workers"')
      expect(html).to include('href="/cogworker/overview?layout=b&queue=default"')
      expect(html).not_to include('href="/workers"')
    end

    it 'Workers quiet!/resume!/stop! actions publish to the process signal channel' do
      manager = Cogworker::Manager.new
      heartbeat = Cogworker::Heartbeat.new(manager)
      heartbeat.send(:beat)
      heartbeat.start!
      # Give the pub/sub subscriber thread time to actually establish its
      # SUBSCRIBE before publishing — Redis pub/sub isn't durable, a publish
      # before the subscribe completes is simply lost.
      wait_for do
        Cogworker.config.redis do |c|
          c.pubsub('numsub', "cogworker:signal:#{Cogworker.identity}")
        end[1].to_i.positive?
      end

      resp = mock.post('/workers/quiet', 'HTTP_SEC_FETCH_SITE' => 'same-origin',
                                         params: { 'identity' => Cogworker.identity })
      expect(resp.status).to eq(302)
      wait_for { manager.quiet? }

      # Unlike stop!, this is a genuine round-trip — `Manager#quiet` is a
      # plain in-memory flag, not a one-way state transition.
      resp = mock.post('/workers/resume', 'HTTP_SEC_FETCH_SITE' => 'same-origin',
                                          params: { 'identity' => Cogworker.identity })
      expect(resp.status).to eq(302)
      wait_for { !manager.quiet? }

      heartbeat.stop!
    end

    it "renders a process's card as Quiet (not Active) once its heartbeat reports quiet: true — a real bug " \
       "once: ProcessSet already converts the raw Redis 'true'/'false' string into an actual boolean, so " \
       "the Web route re-comparing it to the string 'true' again always evaluated false, and every card " \
       'silently showed Active regardless of the process\'s real state' do
      manager = Cogworker::Manager.new
      Cogworker::Heartbeat.new(manager).send(:beat)
      Cogworker.config.redis { |c| c.hset(Cogworker::RedisKeys.process(Cogworker.identity), 'quiet', 'true') }

      body = mock.get('/workers').body
      expect(body).to include('tag-warning">Quiet<')
      expect(body).not_to include('tag-success">Active<')
    end

    it "shows a card's own action button as resume once quiet (not quiet again), and as quiet while still " \
       'active (not resume) — never both at once' do
      manager = Cogworker::Manager.new
      Cogworker::Heartbeat.new(manager).send(:beat)

      active_body = mock.get('/workers').body
      expect(active_body).to include('hx-post="/workers/quiet"')
      expect(active_body).not_to include('hx-post="/workers/resume"')

      Cogworker.config.redis { |c| c.hset(Cogworker::RedisKeys.process(Cogworker.identity), 'quiet', 'true') }

      quiet_body = mock.get('/workers').body
      expect(quiet_body).to include('hx-post="/workers/resume"')
      expect(quiet_body).not_to include('hx-post="/workers/quiet"')
    end

    it "Workers renders each process's card with its start time, memory usage, and served queues" do
      Cogworker.config.queues = %w[default low]
      manager = Cogworker::Manager.new
      heartbeat = Cogworker::Heartbeat.new(manager)
      heartbeat.send(:beat) # real Heartbeat#beat — exercises the actual current_rss_kb measurement

      body = mock.get('/workers').body
      expect(body).to include('started <time')
      expect(body).to include('default, low')
      # Either a real "n.nM" reading (the common case on any platform with
      # /proc or `ps`) or the graceful "n/a" fallback — never a raw "0M" or
      # a raised exception either way.
      expect(body).to match(%r{\d+\.\dM|n/a})

      heartbeat.stop!
    end

    it 'Workers renders a page header with real process/thread counts and the real heartbeat interval ' \
       "— the mock's own fixed \"12 processes · 96 threads\" replaced with live data" do
      # Two fake processes written directly to Redis (same shape
      # `ProcessSet#each` reads: a `PROCESSES` set membership plus each
      # identity's own hash, `info` holding the JSON heartbeat payload) —
      # simpler and more direct than juggling two real `Heartbeat`
      # background threads just to get a second identity into the set.
      Cogworker.config.redis do |c|
        %w[proc-a proc-b].each do |identity|
          c.sadd(Cogworker::RedisKeys::PROCESSES, identity)
          c.hset(Cogworker::RedisKeys.process(identity),
                 'info', JSON.generate('concurrency' => 3, 'queues' => ['default'], 'started_at' => Time.now.to_f),
                 'busy', '0', 'quiet', 'false')
        end
      end

      body = mock.get('/workers').body
      expect(body).to include('<h2 style="margin: 0 0 4px;">Workers</h2>')
      expect(body).to include('2 processes')
      expect(body).to include('6 threads') # 2 processes × concurrency 3 each
      expect(body).to include("heartbeat every #{Cogworker::Heartbeat::INTERVAL}s")
    end

    it "Workers' in-flight jobs table renders each job's JID, not just its class/queue/thread" do
      gate = Queue.new
      stub_const('SlowBusyJob', Class.new do
        include Cogworker::Worker
        define_method(:perform) { gate.pop }
      end)
      jid = SlowBusyJob.perform_async

      Cogworker.config.concurrency = 1 # one thread is plenty to pick up the single job pushed above
      manager = Cogworker::Manager.new
      manager.start!
      heartbeat = Cogworker::Heartbeat.new(manager)
      # WorkSet is discovered *via* ProcessSet (it only looks under
      # processes ProcessSet already knows about) — a beat has to exist
      # *before* checking WorkSet, not after, or WorkSet always reports 0
      # regardless of whether the job actually registered itself.
      heartbeat.send(:beat)

      wait_for { Cogworker::WorkSet.new.size == 1 }

      body = mock.get('/workers').body
      expect(body).to include('JID')
      expect(body).to include(jid)

      gate << :go
    ensure
      # Push unconditionally before stopping: if an earlier expectation/wait_for
      # above raised, the job thread may still be blocked on `gate.pop`, and
      # `Manager#stop!` joins that thread — without unblocking it first, `stop!`
      # would hang forever instead of cleaning up (an extra push here is
      # harmless if the job already consumed the first one). Also guards
      # against the same test-isolation leak described in the `ensure` comment
      # in `status_spec.rb`.
      gate << :go
      manager&.stop!(timeout: 5)
    end

    it "Workers' own busy count on each card always matches its in-flight jobs table (both come from the " \
       'same real-time WorkSet snapshot) — the count used to come from the last heartbeat instead, which ' \
       'lags behind real-time WorkSet by up to Heartbeat::INTERVAL seconds and could visibly disagree with it' do
      manager = Cogworker::Manager.new
      Cogworker::Heartbeat.new(manager).send(:beat) # publishes busy=0 — no processor has run anything yet

      # Simulate jobs that started *after* that heartbeat (as real ones do,
      # in between the 5s-apart beats) — this is exactly what
      # `Processor#register_in_workers` itself writes, just without a real
      # Processor thread actually running one.
      identity = Cogworker.identity
      3.times do |i|
        job = { 'jid' => "realtime-jid-#{i}", 'class' => 'SlowBusyJob', 'args' => [], 'queue' => 'default' }
        payload = JSON.generate('queue' => 'default', 'payload' => job, 'run_at' => Time.now.to_i)
        Cogworker.config.redis { |c| c.hset("cogworker:workers:#{identity}", "tid-#{i}", payload) }
      end

      body = mock.get('/workers').body
      # The card's own busy/concurrency figure …
      expect(body).to include("3 / #{Cogworker.config.concurrency} busy")
      # … matches how many rows the in-flight jobs table actually shows for
      # it — not the stale "0" the heartbeat published a moment ago.
      expect(body.scan('realtime-jid').size).to eq(3)
    end

    it 'Jobs (covering what used to be the separate Dead/Retries/Scheduled tabs) self-polls, respecting the ' \
       'global live-update toggle' do
      body = mock.get('/jobs').body
      expect(body).to include('id="jobs-content" hx-get="/jobs"')
      expect(body).to include('hx-trigger="every 3s [window.cogworkerLiveUpdate]"')
    end
  end

  describe 'Schedules tab (was Periodic)' do
    def seed_periodic_entry(pjid, cron:, klass:, args: [], unique: nil, last_slot: nil)
      raw = JSON.generate('cron' => cron, 'class' => klass, 'retry' => 0, 'unique' => unique, 'args' => args)
      Cogworker.config.redis do |c|
        c.hset('periodic:schedule', pjid, raw)
        c.set("periodic:last_slot:#{pjid}", last_slot) if last_slot
      end
    end

    it 'shows the empty state when no worker has ever published a periodic schedule' do
      body = mock.get('/schedules').body
      expect(body).to include('Nothing registered yet')
    end

    it 'lists a registered entry with its cron, class, args, computed next run, and unique mode' do
      seed_periodic_entry('pjid1', cron: '*/5 * * * *', klass: 'PeriodicReportJob', args: [{ 'section' => 'daily' }],
                                   unique: 'until_executed', last_slot: (Time.now - 300).to_i)

      body = mock.get('/schedules').body
      expect(body).to include('PeriodicReportJob')
      expect(body).to include('*/5 * * * *')
      expect(body).to include('{&quot;section&quot;:&quot;daily&quot;}')
      expect(body).to include('until_executed')
      expect(body).not_to include('never') # a last_slot was seeded
    end

    it 'shows "never" for an entry that has not fired yet (no periodic:last_slot key)' do
      seed_periodic_entry('pjid2', cron: '0 * * * *', klass: 'NeverRunYetJob')

      body = mock.get('/schedules').body
      expect(body).to include('NeverRunYetJob')
      expect(body).to include('never')
    end

    it 'includes the self-polling container, respecting the same live-update toggle as Workers/Stats/Overview' do
      resp = mock.get('/schedules')
      expect(resp.body).to include('id="schedules-content"')
      expect(resp.body).to include('hx-trigger="every 3s [window.cogworkerLiveUpdate]"')
    end

    it 'shows Enabled by default, and every entry offers run now/disable' do
      seed_periodic_entry('pjid3', cron: '0 * * * *', klass: 'EnabledJob')

      body = mock.get('/schedules').body
      expect(body).to include(Cogworker::Web::Layout.badge('Enabled', variant: :success))
      expect(body).to include('>run now<')
      expect(body).to include('>disable<')
    end

    it 'POST .../run_now pushes the entry\'s class/args as an ordinary job, untied to any periodic slot' do
      seed_periodic_entry('pjid4', cron: '0 * * * *', klass: 'RunNowJob', args: [{ 'x' => 1 }])
      stub_const('RunNowJob', Class.new { include Cogworker::Worker })

      resp = mock.post('/schedules/pjid4/run_now', 'HTTP_HX_REQUEST' => 'true', 'HTTP_SEC_FETCH_SITE' => 'same-origin')

      expect(resp.status).to eq(200)
      raw = Cogworker.config.redis { |c| c.lpop('cogworker:queue:default') }
      job = JSON.parse(raw)
      expect(job['class']).to eq('RunNowJob')
      expect(job['args']).to eq([{ 'x' => 1 }])
      expect(job).not_to have_key('periodic_pjid') # a manual run, not tied to the cron claim/lock bookkeeping
    end

    it 'POST .../disable then .../enable toggles the State tag, the NextRun column, and Ticker#disabled?' do
      seed_periodic_entry('pjid5', cron: '0 * * * *', klass: 'ToggleJob')
      pjid = 'pjid5'

      resp = mock.post("/schedules/#{pjid}/disable", 'HTTP_HX_REQUEST' => 'true',
                                                     'HTTP_SEC_FETCH_SITE' => 'same-origin')
      expect(resp.status).to eq(200)
      expect(resp.body).to include(Cogworker::Web::Layout.badge('Disabled', variant: :warning))
      expect(resp.body).to include('>disabled<') # NextRun column, not a computed time
      expect(resp.body).to include('>enable<')
      expect(Cogworker.config.redis { |c| c.sismember('periodic:disabled', pjid) }).to be(true)

      resp = mock.post("/schedules/#{pjid}/enable", 'HTTP_HX_REQUEST' => 'true',
                                                    'HTTP_SEC_FETCH_SITE' => 'same-origin')
      expect(resp.status).to eq(200)
      expect(resp.body).to include(Cogworker::Web::Layout.badge('Enabled', variant: :success))
      expect(Cogworker.config.redis { |c| c.sismember('periodic:disabled', pjid) }).to be(false)
    end

    it 'a plain (non-hx) disable POST still redirects, for JS-less clients' do
      seed_periodic_entry('pjid6', cron: '0 * * * *', klass: 'RedirectJob')
      resp = mock.post('/schedules/pjid6/disable', 'HTTP_SEC_FETCH_SITE' => 'same-origin')
      expect(resp.status).to eq(302)
    end

    it 'renders a page header with a title and a shown/total count' do
      seed_periodic_entry('pjid7', cron: '0 * * * *', klass: 'HeaderJob')

      body = mock.get('/schedules').body
      expect(body).to include('<h2 style="margin: 0 0 4px;">Schedules</h2>')
      expect(body).to include('1 of 1 shown')
    end

    it '?q= searches class, cron, and args, narrowing the table and the shown/total count' do
      seed_periodic_entry('pjidmatch', cron: '*/5 * * * *', klass: 'MatchingReportJob', args: [{ 'x' => 1 }])
      seed_periodic_entry('pjidother', cron: '0 0 * * *', klass: 'OtherJob')

      body = mock.get('/schedules?q=Matching').body
      expect(body).to include('MatchingReportJob')
      expect(body).not_to include('OtherJob')
      expect(body).to include('1 of 2 shown')

      # Matches the cron expression too, not just the class name.
      body = mock.get('/schedules?q=0+0+*+*+*').body
      expect(body).to include('OtherJob')
      expect(body).not_to include('MatchingReportJob')
    end

    it 'shows a search-specific empty message when a query matches nothing, distinct from the ' \
       "'nothing registered at all' state" do
      seed_periodic_entry('pjidreal', cron: '0 * * * *', klass: 'RealJob')

      body = mock.get('/schedules?q=NoSuchClass').body
      expect(body).to include('No schedules match that search.')
      expect(body).not_to include('Nothing registered yet')
    end

    it 'a row action (disable) started from an active search carries the search through via a hidden ' \
       'field, so the hx-swapped re-render does not silently clear it' do
      seed_periodic_entry('pjidsearch', cron: '0 * * * *', klass: 'SearchedJob')

      body = mock.get('/schedules?q=Searched').body
      expect(body).to include('<input type="hidden" name="q" value="Searched">')

      resp = mock.post('/schedules/pjidsearch/disable', 'HTTP_HX_REQUEST' => 'true',
                                                        'HTTP_SEC_FETCH_SITE' => 'same-origin',
                                                        params: { 'q' => 'Searched' })
      expect(resp.body).to include('SearchedJob')
      expect(resp.body).to include('value="Searched"') # the search box itself still shows the term
    end

    it 'a plain (non-hx) row action redirects back with ?q= preserved' do
      seed_periodic_entry('pjidredirect2', cron: '0 * * * *', klass: 'RedirectSearchJob')
      resp = mock.post('/schedules/pjidredirect2/disable', 'HTTP_SEC_FETCH_SITE' => 'same-origin',
                                                           params: { 'q' => 'RedirectSearch' })
      expect(resp.status).to eq(302)
      expect(resp.location).to end_with('/schedules?q=RedirectSearch')
    end
  end

  describe 'cluster bar (header status pill + "Pause intake", on every page)' do
    it 'shows a muted dot and "0 workers" when nothing is reporting in' do
      body = mock.get('/overview').body
      expect(body).to include('id="cluster-bar" hx-get="/workers/summary"')
      expect(body).to include('0 workers')
      expect(body).to include('background: var(--color-neutral-600);')
    end

    it 'shows a lit, glowing dot and the real process count once a process has beaten' do
      Cogworker::Heartbeat.new(Cogworker::Manager.new).send(:beat)

      body = mock.get('/overview').body
      expect(body).to include('1 worker')
      expect(body).to include('background: var(--color-success);')
      expect(body).to include('box-shadow: 0 0 0 3px color-mix(in srgb, var(--color-success) 22%, transparent);')
    end

    it 'goes back to the muted dot once every process is quiet' do
      manager = Cogworker::Manager.new
      Cogworker::Heartbeat.new(manager).send(:beat)
      manager.quiet!
      Cogworker::Heartbeat.new(manager).send(:beat) # publishes the now-quiet state

      body = mock.get('/overview').body
      expect(body).to include('1 worker')
      expect(body).to include('background: var(--color-neutral-600);')
    end

    it 'GET /workers/summary returns just the bare fragment (no page chrome)' do
      resp = mock.get('/workers/summary')
      expect(resp.status).to eq(200)
      expect(resp.body).not_to include('<html>')
      expect(resp.body).not_to include('id="cluster-bar"') # the bare fragment, not the polling wrapper
      expect(resp.body).to include('workers')
    end

    it 'POST /workers/pause_all quiets every live process, via the same signal pub/sub a single quiet! uses' do
      manager = Cogworker::Manager.new
      heartbeat = Cogworker::Heartbeat.new(manager)
      heartbeat.send(:beat)
      heartbeat.start!
      # Same wait as the single-process quiet test: the pub/sub SUBSCRIBE
      # has to actually be established before pause_all's PUBLISH, or it's
      # simply lost (Redis pub/sub isn't durable).
      wait_for do
        Cogworker.config.redis do |c|
          c.pubsub('numsub', "cogworker:signal:#{Cogworker.identity}")
        end[1].to_i.positive?
      end

      resp = mock.post('/workers/pause_all', 'HTTP_HX_REQUEST' => 'true', 'HTTP_SEC_FETCH_SITE' => 'same-origin')

      expect(resp.status).to eq(200)
      wait_for { manager.quiet? }

      heartbeat.stop!
    end

    it 'a plain (non-hx) POST to pause_all still redirects, for JS-less clients' do
      resp = mock.post('/workers/pause_all', 'HTTP_SEC_FETCH_SITE' => 'same-origin')
      expect(resp.status).to eq(302)
    end

    it 'POST /workers/resume_all resumes every live process, the symmetric undo for pause_all' do
      manager = Cogworker::Manager.new
      heartbeat = Cogworker::Heartbeat.new(manager)
      heartbeat.send(:beat)
      heartbeat.start!
      wait_for do
        Cogworker.config.redis do |c|
          c.pubsub('numsub', "cogworker:signal:#{Cogworker.identity}")
        end[1].to_i.positive?
      end

      mock.post('/workers/pause_all', 'HTTP_HX_REQUEST' => 'true', 'HTTP_SEC_FETCH_SITE' => 'same-origin')
      wait_for { manager.quiet? }

      resp = mock.post('/workers/resume_all', 'HTTP_HX_REQUEST' => 'true', 'HTTP_SEC_FETCH_SITE' => 'same-origin')
      expect(resp.status).to eq(200)
      wait_for { !manager.quiet? }

      heartbeat.stop!
    end

    it 'a plain (non-hx) POST to resume_all still redirects, for JS-less clients' do
      resp = mock.post('/workers/resume_all', 'HTTP_SEC_FETCH_SITE' => 'same-origin')
      expect(resp.status).to eq(302)
    end

    it 'the header renders both Pause intake and Resume intake buttons side by side, not a single toggle' do
      body = mock.get('/workers').body
      expect(body).to include('hx-post="/workers/pause_all"')
      expect(body).to include('hx-post="/workers/resume_all"')
    end
  end

  describe 'offline assets (htmx/nocturne/AG Grid vendored, served via Rack::Static)' do
    it 'serves the vendored htmx/nocturne/AG Grid files locally, at a mount-point-prefixed path' do
      env = Rack::MockRequest.env_for('/assets/htmx.min.js', 'SCRIPT_NAME' => '/cogworker',
                                                             'PATH_INFO' => '/assets/htmx.min.js')
      status, headers, body = Cogworker::Web.call(env)
      expect(status).to eq(200)
      expect(headers['content-type']).to eq('text/javascript')
      chunks = []
      body.each { |chunk| chunks << chunk }
      expect(chunks.join).to include('htmx')

      resp = mock.get('/assets/nocturne/styles.css')
      expect(resp.status).to eq(200)
      expect(resp.headers['content-type']).to eq('text/css')
      expect(resp.body).to include('--color-accent')

      resp = mock.get('/assets/ag-grid/ag-grid-community.min.js')
      expect(resp.status).to eq(200)
      expect(resp.body.bytesize).to be > 100_000

      resp = mock.get('/assets/chart.umd.min.js')
      expect(resp.status).to eq(200)
      expect(resp.body).to include('Chart.js')
      expect(resp.body.bytesize).to be > 100_000
    end

    it 'never references an external CDN host anywhere in a rendered page' do
      %w[/workers /history /stats /overview /schedules].each do |path|
        body = mock.get(path).body
        expect(body).not_to match(%r{https?://})
      end
    end

    it "doesn't mark vendored assets immutable/long-cached — they DO change (a styles.css rebuild, a gem " \
       'upgrade), and an immutable/long max-age previously left a browser serving a stale copy of a ' \
       'vendored asset under the same URL with no revalidation at all until a hard reload' do
      resp = mock.get('/assets/nocturne/styles.css')
      expect(resp.headers['cache-control']).not_to match(/immutable/)
      expect(resp.headers['last-modified']).not_to be_nil # so a normal conditional GET still revalidates cheaply
    end

    it 'serves the vendored nocturne stylesheet/font and Phosphor icon font locally, with no external ' \
       'references — linked on every page (Layout.wrap) since the nocturne migration finished, this ' \
       'proves the assets themselves are in place and offline' do
      resp = mock.get('/assets/nocturne/styles.css')
      expect(resp.status).to eq(200)
      expect(resp.headers['content-type']).to eq('text/css')
      expect(resp.body).not_to match(%r{https?://})
      expect(resp.body).to include('--color-accent')

      resp = mock.get('/assets/nocturne/fonts/inter-latin.woff2')
      expect(resp.status).to eq(200)
      expect(resp.body.bytesize).to be > 10_000

      resp = mock.get('/assets/phosphor/style.css')
      expect(resp.status).to eq(200)
      expect(resp.headers['content-type']).to eq('text/css')
      expect(resp.body).not_to match(%r{https?://})
      expect(resp.body).to include('.ph {')

      resp = mock.get('/assets/phosphor/Phosphor.woff2')
      expect(resp.status).to eq(200)
      expect(resp.body.bytesize).to be > 10_000
    end
  end

  describe 'htmx' do
    def hx_get(path)
      mock.get(path, 'HTTP_HX_REQUEST' => 'true')
    end

    def hx_post(path, params)
      mock.post(path, 'HTTP_HX_REQUEST' => 'true', 'HTTP_SEC_FETCH_SITE' => 'same-origin', params: params)
    end

    it 'includes the htmx script and a self-polling container on a plain (non-hx) page load' do
      resp = mock.get('/workers')
      expect(resp.body).to include('src="/assets/htmx.min.js"') # vendored locally, not fetched from a CDN
      expect(resp.body).to include('id="workers-content"')
      expect(resp.body).to include('hx-trigger="every 3s [window.cogworkerLiveUpdate]"') # default Web.live_update_interval
    end

    it 'Overview layout B (/overview?layout=b&queue=:name) is also a self-polling container, carrying the ' \
       'same query params so a refresh keeps the selected layout/queue' do
      resp = mock.get('/overview?layout=b&queue=default')
      expect(resp.body).to include('id="overview-content"')
      expect(resp.body).to include('hx-get="/overview?layout=b&queue=default"')
      expect(resp.body).to include('hx-trigger="every 3s [window.cogworkerLiveUpdate]"')
    end

    it 'derives the poll interval from Web.live_update_interval, not a hardcoded value — shared across every built-in tab' do
      original = Cogworker::Web.live_update_interval
      Cogworker::Web.live_update_interval = 15

      expect(mock.get('/workers').body).to include('hx-trigger="every 15s [window.cogworkerLiveUpdate]"')
      expect(mock.get('/overview').body).to include('hx-trigger="every 15s [window.cogworkerLiveUpdate]"')
      expect(mock.get('/schedules').body).to include('hx-trigger="every 15s [window.cogworkerLiveUpdate]"')
    ensure
      Cogworker::Web.live_update_interval = original
    end

    it 'includes the global live-update toggle button, gating the poll behind window.cogworkerLiveUpdate' do
      resp = mock.get('/workers')
      expect(resp.body).to include('data-cw-live-toggle')
      expect(resp.body).to include('window.cogworkerSetLiveUpdate(!window.cogworkerLiveUpdate)')
      expect(resp.body).to include('window.cogworkerLiveUpdate = readStored();')
    end

    it 'includes the global fixed-width/full-width toggle, wrapping page content in #cw-main' do
      resp = mock.get('/workers')
      expect(resp.body).to include('id="cw-main" class="cw-main"')
      expect(resp.body).to include('data-cw-wide-toggle')
      expect(resp.body).to include('window.cogworkerSetWideLayout(!window.cogworkerWideLayout)')
      expect(resp.body).to include("main.classList.toggle('cw-main--wide', on)")
    end

    it 'returns just the fragment (no <html>/<nav> chrome) for an hx-request, not a full page' do
      Cogworker::Heartbeat.new(Cogworker::Manager.new).send(:beat) # so the fragment has an actual process card, not the empty-state message

      resp = hx_get('/workers')
      expect(resp.status).to eq(200)
      expect(resp.body).not_to include('<html>')
      expect(resp.body).not_to include('<nav>')
      expect(resp.body).to include('class="card')
    end

    it 'an hx-post action (quiet) returns the refreshed fragment instead of redirecting' do
      manager = Cogworker::Manager.new
      heartbeat = Cogworker::Heartbeat.new(manager)
      heartbeat.send(:beat)
      heartbeat.start!
      wait_for do
        Cogworker.config.redis do |c|
          c.pubsub('numsub', "cogworker:signal:#{Cogworker.identity}")
        end[1].to_i.positive?
      end

      resp = hx_post('/workers/quiet', 'identity' => Cogworker.identity)

      expect(resp.status).to eq(200)
      expect(resp.body).to include('class="card')
      wait_for { manager.quiet? }

      heartbeat.stop!
    end

    it 'a plain (non-hx) POST to the same action still redirects, for JS-less clients' do
      resp = mock.post('/workers/quiet', 'HTTP_SEC_FETCH_SITE' => 'same-origin', params: { 'identity' => 'nobody' })
      expect(resp.status).to eq(302)
    end

    it 'Jobs retrying-delete via hx-post returns the updated (now-empty) fragment and clears its attempt log' do
      stub_const('HxRetryJob', Class.new { include Cogworker::Worker })
      raw = JSON.generate('jid' => 'hx1', 'class' => 'HxRetryJob', 'args' => [], 'queue' => 'default',
                          'error_class' => 'RuntimeError', 'error_message' => 'boom')
      Cogworker.config.redis { |c| c.zadd('cogworker:retry', Time.now.to_f, raw) }
      Cogworker::Attempts.record('hx1', attempt: 1, error: RuntimeError.new('boom'), outcome: 'retrying')

      resp = hx_post('/jobs/retrying/delete', 'raw' => raw)

      expect(resp.status).to eq(200)
      expect(resp.body).not_to include('HxRetryJob')
      expect(Cogworker.config.redis { |c| c.zcard('cogworker:retry') }).to eq(0)
      expect(Cogworker::Attempts.for('hx1')).to eq([])
    end

    it 'Jobs retrying retry_now via hx-post moves the job off cogworker:retry and onto its queue immediately' do
      raw = JSON.generate('jid' => 'hxretry2', 'class' => 'HxRetryNowJob', 'args' => [1], 'queue' => 'default',
                          'error_class' => 'RuntimeError', 'error_message' => 'boom')
      Cogworker.config.redis { |c| c.zadd('cogworker:retry', Time.now.to_f + 60, raw) }

      resp = hx_post('/jobs/retrying/retry_now', 'raw' => raw, 'status' => 'Retrying')

      expect(resp.status).to eq(200)
      expect(resp.body).not_to include('HxRetryNowJob') # gone from the Retrying-filtered view
      expect(Cogworker.config.redis { |c| c.zcard('cogworker:retry') }).to eq(0)
      expect(Cogworker.config.redis { |c| c.lrange('cogworker:queue:default', 0, -1) }).to eq([raw])
    end

    it 'Jobs retrying/reschedule moves the entry to a new score, in-place — same raw payload/attempt count' do
      raw = JSON.generate('jid' => 'reschedjid2', 'class' => 'ReschedJob2', 'args' => [], 'queue' => 'default',
                          'retry_count' => 2)
      Cogworker.config.redis { |c| c.zadd('cogworker:retry', Time.now.to_f + 60, raw) }

      resp = hx_post('/jobs/retrying/reschedule', 'raw' => raw, 'minutes' => '30')

      expect(resp.status).to eq(200)
      score = Cogworker.config.redis { |c| c.zscore('cogworker:retry', raw) }
      expect(score).to be_within(2).of(Time.now.to_f + (30 * 60))
      expect(Cogworker.config.redis { |c| c.zcard('cogworker:retry') }).to eq(1) # not duplicated
    end

    it 'Jobs scheduled/reschedule works the same way on cogworker:schedule' do
      raw = JSON.generate('jid' => 'reschedjid3', 'class' => 'ReschedJob3', 'args' => [], 'queue' => 'default')
      Cogworker.config.redis { |c| c.zadd('cogworker:schedule', Time.now.to_f + 60, raw) }

      resp = hx_post('/jobs/scheduled/reschedule', 'raw' => raw, 'minutes' => '10')

      expect(resp.status).to eq(200)
      score = Cogworker.config.redis { |c| c.zscore('cogworker:schedule', raw) }
      expect(score).to be_within(2).of(Time.now.to_f + (10 * 60))
    end

    it 'reschedule clamps an out-of-range minutes value instead of accepting garbage' do
      raw = JSON.generate('jid' => 'reschedjid4', 'class' => 'ReschedJob4', 'args' => [], 'queue' => 'default')
      Cogworker.config.redis { |c| c.zadd('cogworker:retry', Time.now.to_f + 60, raw) }

      hx_post('/jobs/retrying/reschedule', 'raw' => raw, 'minutes' => '999999999')

      score = Cogworker.config.redis { |c| c.zscore('cogworker:retry', raw) }
      max_expected = Time.now.to_f + (Cogworker::Web::Routes::Jobs::RESCHEDULE_MAX_MINUTES * 60)
      expect(score).to be_within(2).of(max_expected)
    end

    it 'reschedule silently no-ops if the entry was already deleted/retried by another tab — zrem losing ' \
       "means there's nothing left to move" do
      raw = JSON.generate('jid' => 'goneraw', 'class' => 'GoneJob', 'args' => [], 'queue' => 'default')
      # never added to cogworker:retry — simulates it having already been removed

      resp = hx_post('/jobs/retrying/reschedule', 'raw' => raw, 'minutes' => '5')

      expect(resp.status).to eq(200)
      expect(Cogworker.config.redis { |c| c.zcard('cogworker:retry') }).to eq(0)
    end

    it 'Jobs Dead-delete via hx-post returns the updated (now-empty) fragment and clears its attempt log' do
      raw = JSON.generate('jid' => 'hxdead1', 'class' => 'HxDeadJob', 'args' => [], 'queue' => 'default',
                          'error_class' => 'RuntimeError', 'error_message' => 'boom')
      Cogworker.config.redis { |c| c.zadd('cogworker:dead', Time.now.to_f, raw) }
      Cogworker::Attempts.record('hxdead1', attempt: 1, error: RuntimeError.new('boom'), outcome: 'dead')

      resp = hx_post('/jobs/dead/delete', 'raw' => raw)

      expect(resp.status).to eq(200)
      expect(resp.body).not_to include('HxDeadJob')
      expect(Cogworker.config.redis { |c| c.zcard('cogworker:dead') }).to eq(0)
      expect(Cogworker::Attempts.for('hxdead1')).to eq([])
    end

    it 'Jobs Dead-retry via hx-post moves the job off cogworker:dead and onto its queue for another attempt' do
      raw = JSON.generate('jid' => 'hxdead2', 'class' => 'HxDeadRetryJob', 'args' => [1], 'queue' => 'default',
                          'error_class' => 'RuntimeError', 'error_message' => 'boom')
      Cogworker.config.redis { |c| c.zadd('cogworker:dead', Time.now.to_f, raw) }

      resp = hx_post('/jobs/dead/retry', 'raw' => raw, 'status' => 'Dead')

      expect(resp.status).to eq(200)
      expect(resp.body).not_to include('HxDeadRetryJob') # gone from the Dead-filtered view
      expect(Cogworker.config.redis { |c| c.zcard('cogworker:dead') }).to eq(0)
      expect(Cogworker.config.redis { |c| c.lrange('cogworker:queue:default', 0, -1) }).to eq([raw])
    end

    it "retrying the same Dead entry twice doesn't double-enqueue it — zrem returning 0 the second time gates it" do
      raw = JSON.generate('jid' => 'hxdead3', 'class' => 'HxDeadRetryOnceJob', 'args' => [], 'queue' => 'default')
      Cogworker.config.redis { |c| c.zadd('cogworker:dead', Time.now.to_f, raw) }

      2.times { hx_post('/jobs/dead/retry', 'raw' => raw) }

      expect(Cogworker.config.redis { |c| c.lrange('cogworker:queue:default', 0, -1) }).to eq([raw])
    end

    it 'Jobs Dead-delete-all via hx-post clears every dead entry (and its attempt log) at once' do
      %w[one two].each do |jid|
        raw = JSON.generate('jid' => jid, 'class' => "HxDeadAll#{jid.capitalize}Job", 'args' => [],
                            'queue' => 'default')
        Cogworker.config.redis { |c| c.zadd('cogworker:dead', Time.now.to_f, raw) }
        Cogworker::Attempts.record(jid, attempt: 1, error: RuntimeError.new('boom'), outcome: 'dead')
      end

      resp = hx_post('/jobs/dead/delete_all', {})

      expect(resp.status).to eq(200)
      expect(resp.body).not_to include('HxDeadAllOneJob')
      expect(resp.body).not_to include('HxDeadAllTwoJob')
      expect(Cogworker.config.redis { |c| c.zcard('cogworker:dead') }).to eq(0)
      expect(Cogworker::Attempts.for('one')).to eq([])
      expect(Cogworker::Attempts.for('two')).to eq([])
    end

    it 'Overview delete via hx-post removes a single job and returns the updated fragment' do
      raw_one = JSON.generate('jid' => 'hxq1', 'class' => 'HxQueueOneJob', 'args' => [], 'queue' => 'default')
      raw_two = JSON.generate('jid' => 'hxq2', 'class' => 'HxQueueTwoJob', 'args' => [], 'queue' => 'default')
      Cogworker.config.redis do |c|
        c.lpush('cogworker:queue:default', raw_one)
        c.lpush('cogworker:queue:default', raw_two)
      end

      resp = hx_post('/overview/default/delete', 'raw' => raw_one)

      expect(resp.status).to eq(200)
      expect(resp.body).not_to include('HxQueueOneJob')
      expect(resp.body).to include('HxQueueTwoJob')
      expect(Cogworker.config.redis { |c| c.lrange('cogworker:queue:default', 0, -1) }).to eq([raw_two])
    end

    it 'Overview delete all via hx-post clears every job on that queue at once' do
      %w[one two].each do |jid|
        raw = JSON.generate('jid' => jid, 'class' => "HxQueueAll#{jid.capitalize}Job", 'args' => [],
                            'queue' => 'default')
        Cogworker.config.redis { |c| c.lpush('cogworker:queue:default', raw) }
      end

      resp = hx_post('/overview/default/delete_all', {})

      expect(resp.status).to eq(200)
      expect(resp.body).not_to include('HxQueueAllOneJob')
      expect(resp.body).not_to include('HxQueueAllTwoJob')
      expect(Cogworker.config.redis { |c| c.llen('cogworker:queue:default') }).to eq(0)
    end

    it "Overview hides the 'delete all' button once the queue has nothing left to delete" do
      raw = JSON.generate('jid' => 'hxqlast', 'class' => 'HxQueueLastJob', 'args' => [], 'queue' => 'default')
      Cogworker.config.redis { |c| c.lpush('cogworker:queue:default', raw) }

      expect(mock.get('/overview?layout=b&queue=default').body).to include('delete all')

      resp = hx_post('/overview/default/delete_all', {})

      expect(resp.body).not_to include('delete all')
    end

    it 'Overview pause/resume via hx-post toggle Queue#paused? and the rendered tag/button' do
      resp = hx_post('/overview/default/pause', 'layout' => 'b')
      expect(resp.status).to eq(200)
      expect(Cogworker::Queue.new('default').paused?).to be(true)
      expect(resp.body).to include(Cogworker::Web::Layout.badge('paused', variant: :warning))
      expect(resp.body).to include('>resume<')

      resp = hx_post('/overview/default/resume', 'layout' => 'b')
      expect(resp.status).to eq(200)
      expect(Cogworker::Queue.new('default').paused?).to be(false)
      expect(resp.body).not_to include(Cogworker::Web::Layout.badge('paused', variant: :warning))
      expect(resp.body).to include('>pause<')
    end

    it 'Overview pause from layout A (the queue table) stays on layout A, not layout B, after the hx-post' do
      resp = hx_post('/overview/default/pause', 'layout' => 'a')
      expect(resp.status).to eq(200)
      # Layout A's own page header ("Overview" + the A/B segmented switch),
      # not layout B's per-queue detail pane (which has no page header of
      # its own inside the polled fragment).
      expect(resp.body).to include('>Overview<')
      expect(resp.body).to include('Metrics first')
    end

    it 'a plain (non-hx) pause POST still redirects, for JS-less clients' do
      resp = mock.post('/overview/default/pause', 'HTTP_SEC_FETCH_SITE' => 'same-origin')
      expect(resp.status).to eq(302)
    end

    it "Overview's queue table shows a pause button by default, and a resume button plus a paused tag " \
       'once the queue is actually paused' do
      stub_const('OverviewPauseJob', Class.new { include Cogworker::Worker })
      OverviewPauseJob.perform_async

      body = mock.get('/overview').body
      expect(body).to include('>pause<')
      expect(body).not_to include('paused')

      Cogworker::Queue.new('default').pause!
      body = mock.get('/overview').body
      expect(body).to include('>resume<')
      expect(body).to include('paused')
    end

    it "Overview's retry-all button is hidden with nothing retrying, and moves every matching retry " \
       "entry for that queue back onto it — leaving a different queue's own retry entry untouched" do
      raw_default = JSON.generate('jid' => 'retryall1', 'class' => 'RetryAllDefaultJob', 'args' => [],
                                  'queue' => 'default', 'error_class' => 'RuntimeError', 'error_message' => 'boom')
      raw_low = JSON.generate('jid' => 'retryall2', 'class' => 'RetryAllLowJob', 'args' => [], 'queue' => 'low',
                              'error_class' => 'RuntimeError', 'error_message' => 'boom')
      Cogworker.config.redis do |c|
        c.zadd('cogworker:retry', Time.now.to_f + 60, raw_default)
        c.zadd('cogworker:retry', Time.now.to_f + 60, raw_low)
      end

      expect(mock.get('/overview?layout=b&queue=default').body).to include('>retry all<')
      expect(mock.get('/overview?layout=b&queue=low').body).to include('>retry all<')

      resp = hx_post('/overview/default/retry_all', 'layout' => 'b')

      expect(resp.status).to eq(200)
      expect(Cogworker.config.redis { |c| c.zcard('cogworker:retry') }).to eq(1) # only the "low" entry remains
      expect(Cogworker.config.redis { |c| c.lrange('cogworker:queue:default', 0, -1) }).to eq([raw_default])
      expect(Cogworker.config.redis { |c| c.zrange('cogworker:retry', 0, -1) }).to eq([raw_low])
      # Nothing left retrying on "default" any more — the button disappears.
      expect(resp.body).not_to include('>retry all<')
    end
  end

  describe Cogworker::Prometheus::Exporter do
    it 'renders processed/failed/queue metrics as Prometheus text format' do
      resp = mock.get('/metrics')
      expect(resp.status).to eq(200)
      expect(resp.body).to include('cogworker_processed_total')
      expect(resp.body).to include('cogworker_busy_workers')
    end
  end
end
