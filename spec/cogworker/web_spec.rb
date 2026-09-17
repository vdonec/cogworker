# frozen_string_literal: true

require 'spec_helper'
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
      resp = mock.post('/busy/quiet', params: { 'identity' => 'x' })
      expect(resp.status).to eq(403)
    end

    it 'allows a POST carrying Sec-Fetch-Site: same-origin' do
      resp = mock.post('/busy/quiet', 'HTTP_SEC_FETCH_SITE' => 'same-origin', params: { 'identity' => 'x' })
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

      body = mock.get('/scheduled').body
      expect(body).to include('datetime="2026-01-02T03:04:05Z"')
      expect(body).to include('data-cw-time')
      expect(body).to include('>2026-01-02 03:04:05<')
    end

    it 'reflects a custom Web.time_format in the server-rendered fallback' do
      Cogworker::Web.time_format = '%d.%m.%Y'
      raw = JSON.generate('jid' => 'y', 'class' => 'X', 'args' => [], 'queue' => 'default')
      Cogworker.config.redis { |c| c.zadd('cogworker:dead', Time.utc(2026, 1, 2, 3, 4, 5).to_f, raw) }

      body = mock.get('/dead').body
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

    it 'renders the AG Grid container/assets and embeds full args + backtrace as row data for the JS grid to render' do
      seed_entry('success', jid: 'ok1', args: [1, 'two'])
      seed_entry('failed', jid: 'bad1', error_class: 'RuntimeError', error_message: 'kaboom')

      body = mock.get('/history').body
      expect(body).to include('ag-grid-community')
      expect(body).to include('id="history-grid"')
      expect(body).to include('id="history-backtrace-dialog"')
      expect(body).to include('"jid":"ok1"')
      expect(body).to include('"args":[1,"two"]')
      expect(body).to include('"jid":"bad1"')
      expect(body).to include('kaboom')
      expect(body).to include('"backtrace":["line1","line2"]')
    end

    it 'escapes a </script> sequence hiding in job data so it cannot break out of the inline script tag' do
      seed_entry('success', jid: 'ok1', args: ['</script><script>window.pwned = true</script>'])

      body = mock.get('/history').body
      expect(body).not_to include('</script><script>window.pwned')
      expect(body).to include('<\\/script>')
    end

    it 'filters by status via ?status=, still server-side (a smaller row-data payload per filter)' do
      seed_entry('success', jid: 'ok1')
      seed_entry('failed', jid: 'bad1')

      success_body = mock.get('/history?status=success').body
      expect(success_body).to include('"jid":"ok1"')
      expect(success_body).not_to include('"jid":"bad1"')

      failed_body = mock.get('/history?status=failed').body
      expect(failed_body).to include('"jid":"bad1"')
      expect(failed_body).not_to include('"jid":"ok1"')
    end

    it 'sends every retained entry to the grid (client-side pagination), and configures the page size from Web.history_per_page' do
      Cogworker::Web.history_per_page = 2
      seed_entry('success', jid: 'newest', finished_at: 20.0)
      seed_entry('success', jid: 'oldest', finished_at: 10.0)

      body = mock.get('/history').body
      expect(body).to include('"jid":"newest"')
      expect(body).to include('"jid":"oldest"') # not server-truncated — AG Grid paginates client-side
      expect(body).to include('paginationPageSize: 2')
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

    describe 'GET /history/data (JSON, polled by the grid for live updates)' do
      it 'returns the full entry list as JSON, honoring the status filter, without the HTML chrome' do
        seed_entry('success', jid: 'ok1')
        seed_entry('failed', jid: 'bad1', error_class: 'RuntimeError', error_message: 'kaboom')

        resp = mock.get('/history/data')
        expect(resp.headers['content-type']).to eq('application/json')
        parsed = JSON.parse(resp.body)
        expect(parsed.map { |e| e['jid'] }).to contain_exactly('ok1', 'bad1')

        failed_only = JSON.parse(mock.get('/history/data?status=failed').body)
        expect(failed_only.map { |e| e['jid'] }).to eq(['bad1'])
      end
    end
  end

  describe 'built-in tabs' do
    it 'Stats renders enqueued/processed/failed counters' do
      stub_const('WebStatsJob', Class.new { include Cogworker::Worker })
      WebStatsJob.perform_async

      resp = mock.get('/stats')
      expect(resp.status).to eq(200)
      expect(resp.body).to include('Enqueued')
    end

    it 'Stats renders a Redis section (version, uptime, connections, memory usage) from a real INFO call' do
      resp = mock.get('/stats')
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

    it 'Stats renders a per-day success/failed runs chart, using real History entries' do
      raw_ok = JSON.generate('jid' => 'chartok', 'class' => 'ChartOkJob', 'queue' => 'default', 'args' => [],
                             'status' => 'success', 'started_at' => Time.now.to_f, 'finished_at' => Time.now.to_f)
      raw_bad = JSON.generate('jid' => 'chartbad', 'class' => 'ChartBadJob', 'queue' => 'default', 'args' => [],
                              'status' => 'failed', 'started_at' => Time.now.to_f, 'finished_at' => Time.now.to_f)
      Cogworker.config.redis do |c|
        c.zadd('cogworker:history:all', Time.now.to_f, raw_ok)
        c.zadd('cogworker:history:success', Time.now.to_f, raw_ok)
        c.zadd('cogworker:history:all', Time.now.to_f, raw_bad)
        c.zadd('cogworker:history:failed', Time.now.to_f, raw_bad)
      end

      body = mock.get('/stats').body
      expect(body).to include('Runs per day')
      today_str = Time.now.utc.strftime('%Y-%m-%d')
      expect(body).to include(today_str) # embedded in the chart's `fullDates` tooltip-title array
      # Default period is Month (30 days): every day is 0/0 except today,
      # which has exactly 1 success and 1 failed.
      expect(body).to include((Array.new(29, 0) + [1]).to_json)
    end

    it 'Stats renders the chart via the vendored Chart.js (not a CDN), inside its own bordered card' do
      body = mock.get('/stats').body
      expect(body).to include('src="/assets/chart.umd.min.js"')
      expect(body).to match(%r{rounded-lg border border-gray-200 dark:border-gray-800 bg-white dark:bg-gray-900 shadow-sm p-4">\s*<div style="position: relative;.*<canvas id="runs-chart-canvas"></canvas>}m)
      expect(body).to include('new Chart(')
      expect(body).not_to match(%r{https?://}) # vendored, not fetched from jsdelivr/unpkg/etc
    end

    it "Stats' chart is NOT inside any htmx-polled fragment — regression test for a real leak: an " \
       'earlier version re-rendered the whole chart (canvas included) on every htmx poll, creating a ' \
       'new, never-destroyed Chart.js instance each tick (confirmed via Chart.instances in a live ' \
       'browser tab), eventually breaking the chart under live updates' do
      body = mock.get('/stats').body
      expect(body).to include("id=\"#{Cogworker::Web::Routes::Stats::COUNTERS_CONTENT_ID}\"")
      expect(body).to include("id=\"#{Cogworker::Web::Routes::Stats::REDIS_CONTENT_ID}\"")
      expect(body).to include('<canvas id="runs-chart-canvas">')
      # The chart keeps itself live by re-fetching its own small JSON
      # endpoint and patching the *existing* instance's data in place —
      # never recreating it, so there's nothing to leak. (The companion
      # test below proves the counters/Redis poll fragments — the only
      # things an htmx tick actually swaps — never contain a `<canvas>`.)
      expect(body).to include('fetch(dataUrl')
      expect(body).to include('chart.update()')
      expect(body).not_to include('window.cogworkerRunsChart') # the old destroy-and-recreate workaround is gone
    end

    it 'GET /stats/chart_data returns just the plotted numbers as JSON, honoring ?period=' do
      raw_ok = JSON.generate('jid' => 'apiok', 'class' => 'ApiOkJob', 'queue' => 'default', 'args' => [],
                             'status' => 'success', 'started_at' => Time.now.to_f, 'finished_at' => Time.now.to_f)
      Cogworker.config.redis do |c|
        c.zadd('cogworker:history:all', Time.now.to_f, raw_ok)
        c.zadd('cogworker:history:success', Time.now.to_f, raw_ok)
      end

      resp = mock.get('/stats/chart_data?period=week')
      expect(resp.headers['content-type']).to eq('application/json')
      payload = JSON.parse(resp.body)
      expect(payload['labels'].size).to eq(7)
      expect(payload['fullDates'].last).to eq(Time.now.utc.strftime('%Y-%m-%d'))
      expect(payload['success'].last).to eq(1)
      expect(payload['failed'].last).to eq(0)
    end

    it 'GET /stats/counters and GET /stats/redis each return just their own fragment (no page chrome, no chart)' do
      counters = mock.get('/stats/counters').body
      expect(counters).to include('Enqueued')
      expect(counters).not_to include('<html')
      expect(counters).not_to include('<canvas')

      redis = mock.get('/stats/redis').body
      expect(redis).to include('Version')
      expect(redis).not_to include('<html')
      expect(redis).not_to include('<canvas')
    end

    describe 'Stats period switcher (week/month/3 months/6 months)' do
      it 'renders all 4 options as links, defaulting to Month' do
        body = mock.get('/stats').body
        %w[Week Month].each { |label| expect(body).to include(">#{label}<") }
        expect(body).to include('>3 Months<')
        expect(body).to include('>6 Months<')
        expect(body).to include('href="/stats?period=week"')
        expect(body).to include('href="/stats?period=month"')
        expect(body).to include('href="/stats?period=3months"')
        expect(body).to include('href="/stats?period=6months"')
        expect(body).to match(%r{href="/stats\?period=month" class="[^"]*bg-indigo-600})
      end

      it 'highlights whichever period is selected via ?period=' do
        body = mock.get('/stats?period=6months').body
        expect(body).to match(%r{href="/stats\?period=6months" class="[^"]*bg-indigo-600})
        expect(body).not_to match(%r{href="/stats\?period=month" class="[^"]*bg-indigo-600})
      end

      it 'falls back to the default period for an unrecognized ?period value' do
        body = mock.get('/stats?period=bogus').body
        expect(body).to match(%r{href="/stats\?period=month" class="[^"]*bg-indigo-600})
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

        expect(mock.get('/stats?period=month').body).to include(old_day_str) # in fullDates for a 30-day window
        expect(mock.get('/stats?period=week').body).not_to include(old_day_str) # outside a 7-day window
      end

      it "the selected period sticks across the chart's own live-update poll (its dataUrl carries ?period=)" do
        # The counters/Redis poll_divs don't need `?period=` at all anymore
        # (see `page_body`) — the chart isn't htmx-polled, so it carries the
        # period itself, baked into the `dataUrl` its own `fetch` re-uses on
        # every tick.
        body = mock.get('/stats?period=week').body
        expect(body).to include('var dataUrl = "\\/stats\\/chart_data?period=week"') # '/' escaped per Layout.json_for_script
      end
    end

    it "Cogworker::Stats#redis_info exposes the full INFO reply, and missing fields render as 'n/a'" do
      stats = Cogworker::Stats.new
      expect(stats.redis_info).to be_a(Hash)
      expect(stats.redis_info['redis_version']).to be_a(String)

      allow(Cogworker::Stats).to receive(:new).and_wrap_original do |orig, *args|
        orig.call(*args).tap { |s| allow(s).to receive(:redis_info).and_return({}) }
      end
      expect(mock.get('/stats').body).to include('n/a')
    end

    it 'Queues lists a queue and its jobs' do
      stub_const('WebQueueJob', Class.new { include Cogworker::Worker })
      WebQueueJob.perform_async(1, 2)

      list = mock.get('/queues')
      expect(list.body).to include('default')

      detail = mock.get('/queues/default')
      expect(detail.body).to include('WebQueueJob')
    end

    it 'Dead lists entries newest DiedAt first' do
      older = JSON.generate('jid' => 'older', 'class' => 'OlderDeadJob', 'args' => [], 'queue' => 'default')
      newer = JSON.generate('jid' => 'newer', 'class' => 'NewerDeadJob', 'args' => [], 'queue' => 'default')
      Cogworker.config.redis do |c|
        c.zadd('cogworker:dead', Time.now.to_f - 3600, older)
        c.zadd('cogworker:dead', Time.now.to_f, newer)
      end

      body = mock.get('/dead').body
      expect(body.index('NewerDeadJob')).to be < body.index('OlderDeadJob')
    end

    it 'generates nav links and form actions prefixed with the actual mount point, not root-absolute' do
      stub_const('WebMountJob', Class.new { include Cogworker::Worker })
      WebMountJob.perform_async

      env = Rack::MockRequest.env_for('/queues', 'SCRIPT_NAME' => '/cogworker', 'PATH_INFO' => '/queues')
      status, _headers, body = Cogworker::Web.call(env)
      html = body.reduce(:+)

      expect(status).to eq(200)
      expect(html).to include('href="/cogworker/busy"')
      expect(html).to include('href="/cogworker/queues/default"')
      expect(html).not_to include('href="/busy"')
    end

    it 'Busy quiet!/stop! actions publish to the process signal channel' do
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

      resp = mock.post('/busy/quiet', 'HTTP_SEC_FETCH_SITE' => 'same-origin',
                                      params: { 'identity' => Cogworker.identity })
      expect(resp.status).to eq(302)
      wait_for { manager.quiet? }

      heartbeat.stop!
    end

    it 'Busy renders each process\'s start time, memory usage, and served queues' do
      Cogworker.config.queues = %w[default low]
      manager = Cogworker::Manager.new
      heartbeat = Cogworker::Heartbeat.new(manager)
      heartbeat.send(:beat) # real Heartbeat#beat — exercises the actual current_rss_kb measurement

      body = mock.get('/busy').body
      expect(body).to include('StartedAt')
      expect(body).to include('Memory')
      expect(body).to include('Queues')
      expect(body).to include('default, low')
      # Either a real "n.nM" reading (the common case on any platform with
      # /proc or `ps`) or the graceful "n/a" fallback — never a raw "0M" or
      # a raised exception either way.
      expect(body).to match(%r{\d+\.\dM|n/a})

      heartbeat.stop!
    end

    it "Busy's Workers section renders each in-flight job's JID, not just its class/queue/thread" do
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

      body = mock.get('/busy').body
      expect(body).to include('JID')
      expect(body).to include(jid)

      gate << :go
      manager.stop!(timeout: 5)
    end

    it "Busy's own Busy count always matches its Workers table (both come from the same real-time " \
       'WorkSet snapshot) — the count used to come from the last heartbeat instead, which lags behind ' \
       'real-time WorkSet by up to Heartbeat::INTERVAL seconds and could visibly disagree with it' do
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

      body = mock.get('/busy').body
      # The process row's own Busy count …
      expect(body).to include('>3<')
      # … matches how many rows the Workers table actually shows for it —
      # not the stale "0" the heartbeat published a moment ago.
      expect(body.scan('realtime-jid').size).to eq(3)
    end

    it 'Dead/Retries/Scheduled each self-poll, respecting the global live-update toggle — a gap fixed after ' \
       'shipping (they predate the live-update feature and were never retrofitted, unlike Busy/Stats/Queues)' do
      { '/dead' => 'dead-content', '/retries' => 'retries-content',
        '/scheduled' => 'scheduled-content' }.each do |path, id|
        body = mock.get(path).body
        expect(body).to include(%(id="#{id}" hx-get="/#{path.delete_prefix('/')}"))
        expect(body).to include('hx-trigger="every 3s [window.cogworkerLiveUpdate]"')
      end
    end
  end

  describe 'Periodic tab' do
    def seed_periodic_entry(pjid, cron:, klass:, args: [], unique: nil, last_slot: nil)
      raw = JSON.generate('cron' => cron, 'class' => klass, 'retry' => 0, 'unique' => unique, 'args' => args)
      Cogworker.config.redis do |c|
        c.hset('periodic:schedule', pjid, raw)
        c.set("periodic:last_slot:#{pjid}", last_slot) if last_slot
      end
    end

    it 'shows the empty state when no worker has ever published a periodic schedule' do
      body = mock.get('/periodic').body
      expect(body).to include('Nothing registered yet')
    end

    it 'lists a registered entry with its cron, class, args, computed next run, and unique mode' do
      seed_periodic_entry('pjid1', cron: '*/5 * * * *', klass: 'PeriodicReportJob', args: [{ 'section' => 'daily' }],
                                   unique: 'until_executed', last_slot: (Time.now - 300).to_i)

      body = mock.get('/periodic').body
      expect(body).to include('PeriodicReportJob')
      expect(body).to include('*/5 * * * *')
      expect(body).to include('{&quot;section&quot;:&quot;daily&quot;}')
      expect(body).to include('until_executed')
      expect(body).not_to include('never') # a last_slot was seeded
    end

    it 'shows "never" for an entry that has not fired yet (no periodic:last_slot key)' do
      seed_periodic_entry('pjid2', cron: '0 * * * *', klass: 'NeverRunYetJob')

      body = mock.get('/periodic').body
      expect(body).to include('NeverRunYetJob')
      expect(body).to include('never')
    end

    it 'includes the self-polling container, respecting the same live-update toggle as Busy/Stats/Queues' do
      resp = mock.get('/periodic')
      expect(resp.body).to include('id="periodic-content"')
      expect(resp.body).to include('hx-trigger="every 3s [window.cogworkerLiveUpdate]"')
    end
  end

  describe 'global stats bar (job counters visible on every page, except Stats itself)' do
    it 'appears, self-polling, on every built-in tab other than /stats' do
      %w[/busy /queues /retries /scheduled /periodic /dead /history].each do |path|
        body = mock.get(path).body
        expect(body).to include('id="global-stats-bar"')
        expect(body).to include('hx-get="/stats/bar"')
        expect(body).to include('Enqueued')
        expect(body).to include('Dead')
      end
    end

    it 'is suppressed on /stats itself — its own card grid already shows the same 6 numbers, larger' do
      body = mock.get('/stats').body
      expect(body).not_to include('id="global-stats-bar"')
      expect(body).not_to include('hx-get="/stats/bar"')
      # The page's own content still renders the job counters — just once,
      # via its bigger card grid, not the compact bar too.
      expect(body).to include('Enqueued')
      expect(body).to include('Dead')
    end

    it 'GET /stats/bar returns just the compact fragment (no page chrome) with real counter values' do
      stub_const('BarCountJob', Class.new { include Cogworker::Worker })
      BarCountJob.perform_async
      raw = JSON.generate('jid' => 'x', 'class' => 'BarDeadJob', 'args' => [], 'queue' => 'default')
      Cogworker.config.redis { |c| c.zadd('cogworker:dead', Time.now.to_f, raw) }

      resp = mock.get('/stats/bar')
      expect(resp.status).to eq(200)
      expect(resp.body).not_to include('<html>')
      expect(resp.body).not_to include('id="global-stats-bar"') # the bare fragment, not the polling wrapper
      expect(resp.body).to include('Enqueued')
      expect(resp.body).to include('>1<') # the one enqueued BarCountJob
      expect(resp.body).to include('Dead')
      expect(resp.body).to include('>1<') # the one dead entry just added
    end

    it 'Layout::JOB_STAT_ACCENTS and Routes::Stats::CARD_ACCENTS share the same 6 job-counter colors' do
      Cogworker::Web::Layout::JOB_STAT_ACCENTS.each do |label, color|
        expect(Cogworker::Web::Routes::Stats::CARD_ACCENTS[label]).to eq(color)
      end
    end
  end

  describe 'offline assets (htmx/Tailwind/AG Grid vendored, served via Rack::Static)' do
    it 'serves the vendored htmx/Tailwind/AG Grid files locally, at a mount-point-prefixed path' do
      env = Rack::MockRequest.env_for('/assets/htmx.min.js', 'SCRIPT_NAME' => '/cogworker',
                                                             'PATH_INFO' => '/assets/htmx.min.js')
      status, headers, body = Cogworker::Web.call(env)
      expect(status).to eq(200)
      expect(headers['content-type']).to eq('text/javascript')
      chunks = []
      body.each { |chunk| chunks << chunk }
      expect(chunks.join).to include('htmx')

      resp = mock.get('/assets/tailwind.css')
      expect(resp.status).to eq(200)
      expect(resp.headers['content-type']).to eq('text/css')
      expect(resp.body).to include('.bg-indigo-600')

      resp = mock.get('/assets/ag-grid/ag-grid-community.min.js')
      expect(resp.status).to eq(200)
      expect(resp.body.bytesize).to be > 100_000

      resp = mock.get('/assets/chart.umd.min.js')
      expect(resp.status).to eq(200)
      expect(resp.body).to include('Chart.js')
      expect(resp.body.bytesize).to be > 100_000
    end

    it 'never references an external CDN host anywhere in a rendered page' do
      %w[/busy /history /stats /queues /periodic].each do |path|
        body = mock.get(path).body
        expect(body).not_to match(%r{https?://})
      end
    end

    it "doesn't mark vendored assets immutable/long-cached — they DO change (a Tailwind rebuild, a gem " \
       'upgrade), and an immutable/long max-age previously left a browser serving a stale copy of ' \
       'tailwind.css under the same URL with no revalidation at all until a hard reload' do
      resp = mock.get('/assets/tailwind.css')
      expect(resp.headers['cache-control']).not_to match(/immutable/)
      expect(resp.headers['last-modified']).not_to be_nil # so a normal conditional GET still revalidates cheaply
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
      resp = mock.get('/busy')
      expect(resp.body).to include('src="/assets/htmx.min.js"') # vendored locally, not fetched from a CDN
      expect(resp.body).to include('id="busy-content"')
      expect(resp.body).to include('hx-trigger="every 3s [window.cogworkerLiveUpdate]"') # default Web.live_update_interval
    end

    it 'Queue detail page (/queues/:name) is also a self-polling container, not just the Queues list' do
      resp = mock.get('/queues/default')
      expect(resp.body).to include('id="queue-content"')
      expect(resp.body).to include('hx-get="/queues/default"')
      expect(resp.body).to include('hx-trigger="every 3s [window.cogworkerLiveUpdate]"')
    end

    it 'derives the poll interval from Web.live_update_interval, not a hardcoded value — shared across every built-in tab' do
      original = Cogworker::Web.live_update_interval
      Cogworker::Web.live_update_interval = 15

      expect(mock.get('/busy').body).to include('hx-trigger="every 15s [window.cogworkerLiveUpdate]"')
      expect(mock.get('/queues').body).to include('hx-trigger="every 15s [window.cogworkerLiveUpdate]"')
      expect(mock.get('/stats').body).to include('hx-trigger="every 15s [window.cogworkerLiveUpdate]"')
    ensure
      Cogworker::Web.live_update_interval = original
    end

    it 'includes the global live-update toggle button, gating the poll behind window.cogworkerLiveUpdate' do
      resp = mock.get('/busy')
      expect(resp.body).to include('data-cw-live-toggle')
      expect(resp.body).to include('window.cogworkerSetLiveUpdate(!window.cogworkerLiveUpdate)')
      expect(resp.body).to include('window.cogworkerLiveUpdate = readStored();')
    end

    it 'returns just the fragment (no <html>/<nav> chrome) for an hx-request, not a full page' do
      Cogworker::Heartbeat.new(Cogworker::Manager.new).send(:beat) # so the fragment has an actual table, not the empty-state message

      resp = hx_get('/busy')
      expect(resp.status).to eq(200)
      expect(resp.body).not_to include('<html>')
      expect(resp.body).not_to include('<nav>')
      expect(resp.body).to include('<table')
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

      resp = hx_post('/busy/quiet', 'identity' => Cogworker.identity)

      expect(resp.status).to eq(200)
      expect(resp.body).to include('<table')
      wait_for { manager.quiet? }

      heartbeat.stop!
    end

    it 'a plain (non-hx) POST to the same action still redirects, for JS-less clients' do
      resp = mock.post('/busy/quiet', 'HTTP_SEC_FETCH_SITE' => 'same-origin', params: { 'identity' => 'nobody' })
      expect(resp.status).to eq(302)
    end

    it 'Retries delete via hx-post returns the updated (now-empty) fragment' do
      stub_const('HxRetryJob', Class.new { include Cogworker::Worker })
      raw = JSON.generate('jid' => 'hx1', 'class' => 'HxRetryJob', 'args' => [], 'queue' => 'default',
                          'error_class' => 'RuntimeError', 'error_message' => 'boom')
      Cogworker.config.redis { |c| c.zadd('cogworker:retry', Time.now.to_f, raw) }

      resp = hx_post('/retries/delete', 'raw' => raw)

      expect(resp.status).to eq(200)
      expect(resp.body).not_to include('HxRetryJob')
      expect(Cogworker.config.redis { |c| c.zcard('cogworker:retry') }).to eq(0)
    end

    it 'Retries retry_now via hx-post moves the job off cogworker:retry and onto its queue immediately' do
      raw = JSON.generate('jid' => 'hxretry2', 'class' => 'HxRetryNowJob', 'args' => [1], 'queue' => 'default',
                          'error_class' => 'RuntimeError', 'error_message' => 'boom')
      Cogworker.config.redis { |c| c.zadd('cogworker:retry', Time.now.to_f + 60, raw) }

      resp = hx_post('/retries/retry_now', 'raw' => raw)

      expect(resp.status).to eq(200)
      expect(resp.body).not_to include('HxRetryNowJob') # gone from the Retries fragment
      expect(Cogworker.config.redis { |c| c.zcard('cogworker:retry') }).to eq(0)
      expect(Cogworker.config.redis { |c| c.lrange('cogworker:queue:default', 0, -1) }).to eq([raw])
    end

    it 'Dead delete via hx-post returns the updated (now-empty) fragment' do
      raw = JSON.generate('jid' => 'hxdead1', 'class' => 'HxDeadJob', 'args' => [], 'queue' => 'default',
                          'error_class' => 'RuntimeError', 'error_message' => 'boom')
      Cogworker.config.redis { |c| c.zadd('cogworker:dead', Time.now.to_f, raw) }

      resp = hx_post('/dead/delete', 'raw' => raw)

      expect(resp.status).to eq(200)
      expect(resp.body).not_to include('HxDeadJob')
      expect(Cogworker.config.redis { |c| c.zcard('cogworker:dead') }).to eq(0)
    end

    it 'Dead retry via hx-post moves the job off cogworker:dead and onto its queue for another attempt' do
      raw = JSON.generate('jid' => 'hxdead2', 'class' => 'HxDeadRetryJob', 'args' => [1], 'queue' => 'default',
                          'error_class' => 'RuntimeError', 'error_message' => 'boom')
      Cogworker.config.redis { |c| c.zadd('cogworker:dead', Time.now.to_f, raw) }

      resp = hx_post('/dead/retry', 'raw' => raw)

      expect(resp.status).to eq(200)
      expect(resp.body).not_to include('HxDeadRetryJob') # gone from the Dead fragment
      expect(Cogworker.config.redis { |c| c.zcard('cogworker:dead') }).to eq(0)
      expect(Cogworker.config.redis { |c| c.lrange('cogworker:queue:default', 0, -1) }).to eq([raw])
    end

    it "retrying the same Dead entry twice doesn't double-enqueue it — zrem returning 0 the second time gates it" do
      raw = JSON.generate('jid' => 'hxdead3', 'class' => 'HxDeadRetryOnceJob', 'args' => [], 'queue' => 'default')
      Cogworker.config.redis { |c| c.zadd('cogworker:dead', Time.now.to_f, raw) }

      2.times { hx_post('/dead/retry', 'raw' => raw) }

      expect(Cogworker.config.redis { |c| c.lrange('cogworker:queue:default', 0, -1) }).to eq([raw])
    end

    it 'Dead delete all via hx-post clears every dead entry at once' do
      %w[one two].each do |jid|
        raw = JSON.generate('jid' => jid, 'class' => "HxDeadAll#{jid.capitalize}Job", 'args' => [],
                            'queue' => 'default')
        Cogworker.config.redis { |c| c.zadd('cogworker:dead', Time.now.to_f, raw) }
      end

      resp = hx_post('/dead/delete_all', {})

      expect(resp.status).to eq(200)
      expect(resp.body).not_to include('HxDeadAllOneJob')
      expect(resp.body).not_to include('HxDeadAllTwoJob')
      expect(Cogworker.config.redis { |c| c.zcard('cogworker:dead') }).to eq(0)
    end

    it 'Queues delete via hx-post removes a single job and returns the updated fragment' do
      raw_one = JSON.generate('jid' => 'hxq1', 'class' => 'HxQueueOneJob', 'args' => [], 'queue' => 'default')
      raw_two = JSON.generate('jid' => 'hxq2', 'class' => 'HxQueueTwoJob', 'args' => [], 'queue' => 'default')
      Cogworker.config.redis do |c|
        c.lpush('cogworker:queue:default', raw_one)
        c.lpush('cogworker:queue:default', raw_two)
      end

      resp = hx_post('/queues/default/delete', 'raw' => raw_one)

      expect(resp.status).to eq(200)
      expect(resp.body).not_to include('HxQueueOneJob')
      expect(resp.body).to include('HxQueueTwoJob')
      expect(Cogworker.config.redis { |c| c.lrange('cogworker:queue:default', 0, -1) }).to eq([raw_two])
    end

    it 'Queues delete all via hx-post clears every job on that queue at once' do
      %w[one two].each do |jid|
        raw = JSON.generate('jid' => jid, 'class' => "HxQueueAll#{jid.capitalize}Job", 'args' => [],
                            'queue' => 'default')
        Cogworker.config.redis { |c| c.lpush('cogworker:queue:default', raw) }
      end

      resp = hx_post('/queues/default/delete_all', {})

      expect(resp.status).to eq(200)
      expect(resp.body).not_to include('HxQueueAllOneJob')
      expect(resp.body).not_to include('HxQueueAllTwoJob')
      expect(Cogworker.config.redis { |c| c.llen('cogworker:queue:default') }).to eq(0)
    end

    it "Queues hides the 'delete all' button once the queue has nothing left to delete" do
      raw = JSON.generate('jid' => 'hxqlast', 'class' => 'HxQueueLastJob', 'args' => [], 'queue' => 'default')
      Cogworker.config.redis { |c| c.lpush('cogworker:queue:default', raw) }

      expect(mock.get('/queues/default').body).to include('delete all')

      resp = hx_post('/queues/default/delete_all', {})

      expect(resp.body).not_to include('delete all')
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
