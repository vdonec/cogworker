# frozen_string_literal: true

require 'spec_helper'
require_relative '../support/capybara'

# Real-browser tests: these exercise the actual htmx JS running in a real
# (headless) Chrome via Cuprite, unlike web_spec.rb's Rack::MockRequest
# checks (which only prove the server *returns* the right fragment, not that
# the browser actually swaps it in without navigating away). Slower — keep
# scenario count small and let web_spec.rb carry the exhaustive HTTP-level
# coverage.
RSpec.describe 'Web UI (real browser)' do
  include Capybara::DSL

  after { Capybara.reset_sessions! }

  it 'quiets a process via the Busy tab without a full page navigation' do
    manager = Cogworker::Manager.new
    heartbeat = Cogworker::Heartbeat.new(manager)
    heartbeat.send(:beat)
    heartbeat.start!
    wait_for do
      Cogworker.config.redis do |c|
        c.pubsub('numsub', "cogworker:signal:#{Cogworker.identity}")
      end[1].to_i.positive?
    end

    visit '/busy'
    expect(page).to have_content(Cogworker.identity)
    expect(page.current_path).to eq('/busy')

    click_button('quiet')

    # Still the same page (htmx swapped the fragment in place — a fallback
    # plain-form submit would have redirected back to /busy, which *looks*
    # identical in current_path but would prove the JS path was never
    # exercised). The functional check below is what actually matters.
    expect(page.current_path).to eq('/busy')
    wait_for { manager.quiet? }
    # The Redis-stored 'quiet' field only updates on the next periodic
    # heartbeat beat (every INTERVAL seconds), not the instant quiet! fires
    # in-memory — force one now rather than waiting out a real interval.
    heartbeat.send(:beat)
    expect(page).to have_content('quiet', wait: 6) # picked up by the tab's own hx-trigger poll, not a manual reload

    heartbeat.stop!
  end

  it "Stats' chart live-updates via its own JSON poll (not an htmx swap), patching the existing " \
     'Chart.js instance in place rather than recreating it — regression test for a real bug where an ' \
     'earlier version rebuilt the whole chart (canvas included) on every htmx poll, leaking one more ' \
     'never-destroyed instance each tick and eventually breaking the chart under live updates' do
    original_interval = Cogworker::Web.live_update_interval
    Cogworker::Web.live_update_interval = 1

    visit '/stats'
    expect(page).to have_css('canvas#runs-chart-canvas')
    todays_success = 'Object.values(Chart.instances)[0].data.datasets[0].data.slice(-1)[0]'
    expect(page.evaluate_script(todays_success)).to eq(0)

    raw = JSON.generate('jid' => 'chartlive', 'class' => 'ChartLiveJob', 'queue' => 'default', 'args' => [],
                        'status' => 'success', 'started_at' => Time.now.to_f, 'finished_at' => Time.now.to_f)
    Cogworker.config.redis do |c|
      c.zadd('cogworker:history:all', Time.now.to_f, raw)
      c.zadd('cogworker:history:success', Time.now.to_f, raw)
    end

    # No `visit`/reload in between — this only passes if the chart's own
    # `fetch` poll (see `Routes::Stats#chart`'s `refreshChart`), not a full
    # page or htmx-swapped fragment, picked up the new entry and called
    # `chart.update()`.
    wait_for(timeout: 6) { page.evaluate_script(todays_success) == 1 }

    # Still exactly one canvas/instance the whole time — proves the data
    # was patched into the *same* Chart.js instance rather than the widget
    # being torn down and rebuilt (which is what used to leak).
    expect(page.evaluate_script("document.querySelectorAll('canvas').length")).to eq(1)
    expect(page.evaluate_script('Object.keys(Chart.instances).length')).to eq(1)
  ensure
    Cogworker::Web.live_update_interval = original_interval
  end

  it 'Stats auto-refreshes in place a few seconds after a job is processed, with no manual reload' do
    stub_const('SystemStatsJob', Class.new do
      include Cogworker::Worker
      def perform(*); end
    end)
    processed_cell = "//div[div[normalize-space(text())='Processed']]/div[2]"

    visit '/stats'
    expect(page).to have_xpath(processed_cell, text: '0')

    manager = Cogworker::Manager.new
    manager.start!
    SystemStatsJob.perform_async

    # No `visit`/reload call in between — if this passes, it's the page's
    # own `hx-trigger="every 3s"` poll (not a manual navigation) that
    # picked up the change. Asserting one specific cell's value (rather
    # than "no cell says 0" — every *other* metric legitimately stays 0)
    # also avoids a transient false-positive mid-swap, when htmx has
    # cleared the target's innerHTML but not yet inserted the fresh table.
    expect(page).to have_xpath(processed_cell, text: '1', wait: 6)

    manager.stop!(timeout: 2)
  end

  it 'deleting a retry entry removes its row in place' do
    raw = JSON.generate('jid' => 'sysjid', 'class' => 'SystemRetryJob', 'args' => [], 'queue' => 'default',
                        'error_class' => 'RuntimeError', 'error_message' => 'boom')
    Cogworker.config.redis { |c| c.zadd('cogworker:retry', Time.now.to_f, raw) }

    visit '/retries'
    expect(page).to have_content('SystemRetryJob')

    click_button('delete')

    expect(page).to have_no_content('SystemRetryJob')
    expect(page.current_path).to eq('/retries')
  end

  it 'retrying a dead job removes its row in place and puts it back on its queue' do
    raw = JSON.generate('jid' => 'sysdeadjid', 'class' => 'SystemDeadJob', 'args' => [], 'queue' => 'default',
                        'error_class' => 'RuntimeError', 'error_message' => 'boom')
    Cogworker.config.redis { |c| c.zadd('cogworker:dead', Time.now.to_f, raw) }

    visit '/dead'
    expect(page).to have_content('SystemDeadJob')

    click_button('retry')

    expect(page).to have_no_content('SystemDeadJob')
    expect(page.current_path).to eq('/dead')
    expect(Cogworker.config.redis { |c| c.lrange('cogworker:queue:default', 0, -1) }).to eq([raw])
  end

  it 'renders scheduled times in the browser timezone, not server UTC, per the configured format' do
    original_format = Cogworker::Web.time_format
    Cogworker::Web.time_format = '%Y-%m-%d %H:%M:%S'

    # A fixed-offset zone (no DST) so this doesn't get flaky depending on
    # what day it runs: UTC-5, always.
    Capybara.current_session.driver.browser.page.command('Emulation.setTimezoneOverride', timezoneId: 'Etc/GMT+5')

    noon_utc = Time.utc(2026, 6, 15, 12, 0, 0)
    raw = JSON.generate('jid' => 'tzjid', 'class' => 'SystemTzJob', 'args' => [], 'queue' => 'default')
    Cogworker.config.redis { |c| c.zadd('cogworker:schedule', noon_utc.to_f, raw) }

    visit '/scheduled'

    expect(page).to have_content('2026-06-15 07:00:00') # noon UTC, displayed as UTC-5
    expect(page).to have_no_content('2026-06-15 12:00:00') # never the raw UTC fallback text
  ensure
    Cogworker::Web.time_format = original_format
  end

  it 'History tab: expanding a failed run reveals its backtrace, and filter links narrow the list' do
    raw_ok = JSON.generate('jid' => 'sysok', 'class' => 'SysOkJob', 'queue' => 'default', 'args' => [1],
                           'status' => 'success', 'started_at' => 1.0, 'finished_at' => 2.0)
    raw_bad = JSON.generate('jid' => 'sysbad', 'class' => 'SysBadJob', 'queue' => 'default', 'args' => [],
                            'status' => 'failed', 'started_at' => 1.0, 'finished_at' => 3.0,
                            'error_class' => 'RuntimeError', 'error_message' => 'kaboom',
                            'backtrace' => ['app.rb:1:in `perform`'])
    Cogworker.config.redis do |c|
      c.zadd('cogworker:history:all', 2.0, raw_ok)
      c.zadd('cogworker:history:success', 2.0, raw_ok)
      c.zadd('cogworker:history:all', 3.0, raw_bad)
      c.zadd('cogworker:history:failed', 3.0, raw_bad)
    end

    visit '/history'
    expect(page).to have_content('SysOkJob') # AG Grid has finished rendering rowData once this is visible
    expect(page).to have_content('SysBadJob')
    expect(page).to have_no_content('app.rb:1:in `perform`') # backtrace stays out of the grid until opened

    find('.ag-cell', text: 'RuntimeError: kaboom').click
    expect(page).to have_content('app.rb:1:in `perform`') # revealed in the <dialog>, via showModal()
    expect(page.find('#history-backtrace-content').text).to include('RuntimeError: kaboom') # not just the backtrace

    find('dialog button', text: '✕').click
    click_link 'Success'
    expect(page).to have_content('SysOkJob')
    expect(page).to have_no_content('SysBadJob')
  end

  it "History tab: Duration renders in human units ('2h 34m 23s 23ms'), not raw milliseconds — and a " \
     "sub-second job just reads e.g. '45ms', not '0h 0m 0s 45ms'" do
    long_finished = 1000.0 + (2 * 3600) + (34 * 60) + 23 + 0.023
    raw_long = JSON.generate('jid' => 'longjid', 'class' => 'LongJob', 'queue' => 'default', 'args' => [],
                             'status' => 'success', 'started_at' => 1000.0, 'finished_at' => long_finished)
    raw_short = JSON.generate('jid' => 'shortjid', 'class' => 'ShortJob', 'queue' => 'default', 'args' => [],
                              'status' => 'success', 'started_at' => 2000.0, 'finished_at' => 2000.045)
    Cogworker.config.redis do |c|
      c.zadd('cogworker:history:all', 1.0, raw_long)
      c.zadd('cogworker:history:success', 1.0, raw_long)
      c.zadd('cogworker:history:all', 2.0, raw_short)
      c.zadd('cogworker:history:success', 2.0, raw_short)
    end

    visit '/history'
    expect(page).to have_content('LongJob')
    expect(page).to have_content('2h 34m 23s 23ms')
    expect(page).to have_content('45ms')
    expect(page).to have_no_content('0h 0m 0s 45ms')
  end

  it 'the global live-update toggle button flips window.cogworkerLiveUpdate and its own label' do
    visit '/busy'
    expect(page).to have_css('[data-cw-live-toggle]', text: '⏸ Live')
    expect(page.evaluate_script('window.cogworkerLiveUpdate')).to eq(true)

    find('[data-cw-live-toggle]').click
    expect(page).to have_css('[data-cw-live-toggle]', text: '▶ Live')
    expect(page.evaluate_script('window.cogworkerLiveUpdate')).to eq(false)

    find('[data-cw-live-toggle]').click
    expect(page).to have_css('[data-cw-live-toggle]', text: '⏸ Live')
    expect(page.evaluate_script('window.cogworkerLiveUpdate')).to eq(true)
  end

  it 'History tab: live-refreshes newly recorded runs into the grid in place, and stops once live-update is switched off' do
    raw_first = JSON.generate('jid' => 'sysfirst', 'class' => 'SysFirstJob', 'queue' => 'default', 'args' => [],
                              'status' => 'success', 'started_at' => 1.0, 'finished_at' => 2.0)
    Cogworker.config.redis do |c|
      c.zadd('cogworker:history:all', 2.0, raw_first)
      c.zadd('cogworker:history:success', 2.0, raw_first)
    end

    visit '/history'
    expect(page).to have_content('SysFirstJob')

    raw_second = JSON.generate('jid' => 'syslive', 'class' => 'SysLiveJob', 'queue' => 'default', 'args' => [],
                               'status' => 'success', 'started_at' => 3.0, 'finished_at' => 4.0)
    Cogworker.config.redis do |c|
      c.zadd('cogworker:history:all', 4.0, raw_second)
      c.zadd('cogworker:history:success', 4.0, raw_second)
    end

    # No `visit`/reload in between — this proves the grid's own 3s poll (not
    # a manual navigation) picked up the new row.
    expect(page).to have_content('SysLiveJob', wait: 6)
    expect(page.current_path).to eq('/history')

    find('[data-cw-live-toggle]').click
    expect(page).to have_css('[data-cw-live-toggle]', text: '▶ Live')

    raw_third = JSON.generate('jid' => 'sysfrozen', 'class' => 'SysFrozenJob', 'queue' => 'default', 'args' => [],
                              'status' => 'success', 'started_at' => 5.0, 'finished_at' => 6.0)
    Cogworker.config.redis do |c|
      c.zadd('cogworker:history:all', 6.0, raw_third)
      c.zadd('cogworker:history:success', 6.0, raw_third)
    end

    expect(page).to have_no_content('SysFrozenJob', wait: 5) # poll is paused, so this never arrives
  end
end
