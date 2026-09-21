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

  it 'quiets, then resumes, a process via the Workers tab without a full page navigation' do
    manager = Cogworker::Manager.new
    heartbeat = Cogworker::Heartbeat.new(manager)
    heartbeat.send(:beat)
    heartbeat.start!
    wait_for do
      Cogworker.config.redis do |c|
        c.pubsub('numsub', "cogworker:signal:#{Cogworker.identity}")
      end[1].to_i.positive?
    end

    visit '/workers'
    expect(page).to have_content(Cogworker.identity)
    expect(page.current_path).to eq('/workers')

    click_button('quiet')

    # Still the same page (htmx swapped the fragment in place — a fallback
    # plain-form submit would have redirected back to /workers, which
    # *looks* identical in current_path but would prove the JS path was
    # never exercised). The functional check below is what actually matters.
    expect(page.current_path).to eq('/workers')
    wait_for { manager.quiet? }
    # The Redis-stored 'quiet' field only updates on the next periodic
    # heartbeat beat (every INTERVAL seconds), not the instant quiet! fires
    # in-memory — force one now rather than waiting out a real interval.
    heartbeat.send(:beat)
    # Capitalized, and matched case-sensitively: the card's state tag reads
    # "Quiet", distinct from the always-present "quiet" action button label
    # — a loose case-insensitive match here would have silently passed even
    # through the real bug this once had (the tag comparing an already-
    # boolean `quiet` field to the string `'true'` again, so it never
    # actually flipped off "Active").
    expect(page).to have_content('Quiet', wait: 6) # picked up by the tab's own hx-trigger poll, not a manual reload

    # The card's own action button swapped from "quiet" to "resume" along
    # with the state tag — proves the fragment re-render, not just the tag,
    # picked up the new state.
    expect(page).to have_button('resume')
    expect(page).not_to have_button('quiet')

    click_button('resume')
    expect(page.current_path).to eq('/workers')
    wait_for { !manager.quiet? }
    heartbeat.send(:beat)
    expect(page).to have_content('Active', wait: 6)
    expect(page).to have_button('quiet')
    expect(page).not_to have_button('resume')

    heartbeat.stop!
  end

  it "Overview's Runs-per-day chart live-updates via its own JSON poll (not an htmx swap), patching " \
     'the existing Chart.js instance in place rather than recreating it — regression test for a real ' \
     'bug where an earlier version rebuilt the whole chart (canvas included) on every htmx poll, ' \
     'leaking one more never-destroyed instance each tick and eventually breaking the chart under ' \
     'live updates' do
    original_interval = Cogworker::Web.live_update_interval
    Cogworker::Web.live_update_interval = 1

    visit '/overview?layout=a'
    expect(page).to have_css('canvas#overview-runs-canvas')
    todays_success = "Object.values(Chart.instances).find(c => c.canvas.id === 'overview-runs-canvas')" \
                      '.data.datasets[0].data.slice(-1)[0]'
    expect(page.evaluate_script(todays_success)).to eq(0)

    raw = JSON.generate('jid' => 'chartlive', 'class' => 'ChartLiveJob', 'queue' => 'default', 'args' => [],
                        'status' => 'success', 'started_at' => Time.now.to_f, 'finished_at' => Time.now.to_f)
    Cogworker.config.redis do |c|
      c.zadd('cogworker:history:all', Time.now.to_f, raw)
      c.zadd('cogworker:history:success', Time.now.to_f, raw)
    end

    # No `visit`/reload in between — this only passes if the chart's own
    # `fetch` poll (see `Routes::Overview#runs_section`'s `refreshRuns`), not
    # a full page or htmx-swapped fragment, picked up the new entry and
    # called `chart.update()`.
    wait_for(timeout: 6) { page.evaluate_script(todays_success) == 1 }

    # Still exactly one runs-canvas/instance the whole time — proves the data
    # was patched into the *same* Chart.js instance rather than the widget
    # being torn down and rebuilt (which is what used to leak). (Throughput
    # has its own separate canvas/instance alongside it, hence 2 total.)
    expect(page.evaluate_script("document.querySelectorAll('canvas').length")).to eq(2)
    expect(page.evaluate_script('Object.keys(Chart.instances).length')).to eq(2)
  ensure
    Cogworker::Web.live_update_interval = original_interval
  end

  it 'switching the Runs-per-day period patches only that chart — the Throughput chart is never ' \
     'recreated, and no full page navigation happens' do
    old_day = Time.now.utc - (100 * 86_400) # outside Month (30d), inside 6 Months (182d)
    raw = JSON.generate('jid' => 'periodswitch', 'class' => 'PeriodSwitchJob', 'queue' => 'default', 'args' => [],
                        'status' => 'success', 'started_at' => old_day.to_f, 'finished_at' => old_day.to_f)
    Cogworker.config.redis do |c|
      c.zadd('cogworker:history:all', old_day.to_f, raw)
      c.zadd('cogworker:history:success', old_day.to_f, raw)
    end

    visit '/overview?layout=a'
    expect(page).to have_css('canvas#overview-throughput-canvas')
    expect(page).to have_css('canvas#overview-runs-canvas')

    throughput_instance_id = page.evaluate_script(
      "Object.values(Chart.instances).find(c => c.canvas.id === 'overview-throughput-canvas').id"
    )
    runs_label_count = lambda do
      page.evaluate_script(
        "Object.values(Chart.instances).find(c => c.canvas.id === 'overview-runs-canvas').data.labels.length"
      )
    end
    month_labels = runs_label_count.call

    find('label.seg-opt', text: '6 Months').click

    # Runs-per-day actually changed (182 daily buckets instead of 30) —
    # proves the click did something, not just that nothing broke.
    wait_for(timeout: 6) { runs_label_count.call != month_labels }

    # Same Chart.js instance object (same internal `.id`) for Throughput —
    # proves no page navigation and no chart rebuild happened.
    expect(page.evaluate_script(
             "Object.values(Chart.instances).find(c => c.canvas.id === 'overview-throughput-canvas').id"
           )).to eq(throughput_instance_id)
    expect(page.evaluate_script('Object.keys(Chart.instances).length')).to eq(2)
    expect(page.current_path).to eq('/overview') # no navigation away from the page at all
  end

  it "Overview's own Processed counter card auto-refreshes in place a few seconds after a job is " \
     'processed, with no manual reload' do
    stub_const('SystemStatsJob', Class.new do
      include Cogworker::Worker
      def perform(*); end
    end)
    processed_cell = "//div[span[normalize-space(text())='Processed']]/span[2]"

    visit '/overview'
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

    visit '/jobs?status=Retrying'
    expect(page).to have_content('SystemRetryJob')

    click_button('delete')

    expect(page).to have_no_content('SystemRetryJob')
    expect(page.current_path).to eq('/jobs')
  end

  it 'retrying a dead job removes its row in place and puts it back on its queue' do
    raw = JSON.generate('jid' => 'sysdeadjid', 'class' => 'SystemDeadJob', 'args' => [], 'queue' => 'default',
                        'error_class' => 'RuntimeError', 'error_message' => 'boom')
    Cogworker.config.redis { |c| c.zadd('cogworker:dead', Time.now.to_f, raw) }

    visit '/jobs?status=Dead'
    expect(page).to have_content('SystemDeadJob')

    click_button('retry')

    expect(page).to have_no_content('SystemDeadJob')
    expect(page.current_path).to eq('/jobs')
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

    visit '/jobs?status=Scheduled'

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
    # Regression test for a real bug: a native <dialog> ships a UA-default
    # `border-style: solid`, which neither `.dialog`'s `border-radius` nor
    # `box-shadow` override on their own — without an explicit `border:
    # none`, the browser paints its own default border around the themed
    # card underneath, visibly off-style.
    border_style = page.evaluate_script(
      "getComputedStyle(document.getElementById('history-backtrace-dialog')).borderStyle"
    )
    expect(border_style).to eq('none')
    # Regression test for a real bug, same root cause as the border one
    # above: a native <dialog>'s UA stylesheet also sets `color: CanvasText`
    # directly on the element — a *declared* value, not merely inherited —
    # so without `.dialog` overriding `color` explicitly, that UA default
    # wins over the light `--color-text` flowing down from `body`, and the
    # backtrace text renders near-black on `--color-surface`'s dark
    # background: illegible, caught from a real screenshot.
    text_color = page.evaluate_script("getComputedStyle(document.getElementById('history-backtrace-content')).color")
    expect(text_color).not_to match(/rgba?\(0,\s*0,\s*0/) # not black/near-black

    find('dialog button', text: '✕').click
    # A `.seg-opt` radio label now, not an `<a>` — its own `input` is
    # zero-sized/`opacity: 0` (nocturne's custom-radio technique), which
    # Capybara's `choose` treats as "not visible" even though a real user
    # can click the label just fine; click the label itself instead, same
    # as a user would, which still checks the input and fires `onchange`.
    find('label.seg-opt', text: 'Success').click
    expect(page).to have_content('SysOkJob')
    expect(page).to have_no_content('SysBadJob')
  end

  it "History tab: the Status column's pill stays compact, not stretched to the row's own height — " \
     'regression test for a real bug where the pill\'s text inherited AG Grid\'s row-height-driven ' \
     '`.ag-cell { line-height: <rowHeight>px }`, ballooning the pill well past its intended size and ' \
     "getting top/bottom-clipped (rounded corners included) by the cell's own `overflow: hidden`" do
    raw = JSON.generate('jid' => 'syspill', 'class' => 'SysPillJob', 'queue' => 'default', 'args' => [],
                        'status' => 'success', 'started_at' => 1.0, 'finished_at' => 2.0)
    Cogworker.config.redis do |c|
      c.zadd('cogworker:history:all', 2.0, raw)
      c.zadd('cogworker:history:success', 2.0, raw)
    end

    visit '/history'
    expect(page).to have_content('SysPillJob')

    pill_height = page.evaluate_script(<<~JS)
      document.querySelector('.ag-cell[col-id="status"] span span').getBoundingClientRect().height
    JS
    row_height = page.evaluate_script(<<~JS)
      document.querySelector('.ag-cell[col-id="status"]').getBoundingClientRect().height
    JS
    expect(pill_height).to be < (row_height * 0.6) # a real badge, not a cell-height-filling block
  end

  it "History tab: the status filter's .seg control stays compact, not stretched to the full content " \
     'width — regression test for a real bug: as a *direct* child of <main> (display: flex; flex-' \
     'direction: column), an inline-flex `.seg` gets blockified to plain flex and then stretched to the ' \
     "full column width by the ancestor's default align-items: stretch — a mostly-empty bordered box " \
     'with the filter labels bunched at the left, unlike every other `.seg` usage (nested a level or two ' \
     'deeper inside its own page_header, never a direct flex child)' do
    visit '/history'
    seg_width = page.evaluate_script("document.querySelector('.seg').getBoundingClientRect().width")
    main_width = page.evaluate_script("document.getElementById('cw-main').getBoundingClientRect().width")
    expect(seg_width).to be < (main_width * 0.5) # 3 short labels, nowhere near half the page width
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
    visit '/workers'
    expect(page).to have_css('[data-cw-live-toggle]', text: '⏸ Live')
    expect(page.evaluate_script('window.cogworkerLiveUpdate')).to eq(true)

    find('[data-cw-live-toggle]').click
    expect(page).to have_css('[data-cw-live-toggle]', text: '▶ Live')
    expect(page.evaluate_script('window.cogworkerLiveUpdate')).to eq(false)

    find('[data-cw-live-toggle]').click
    expect(page).to have_css('[data-cw-live-toggle]', text: '⏸ Live')
    expect(page.evaluate_script('window.cogworkerLiveUpdate')).to eq(true)
  end

  it 'the fixed-width/full-width toggle flips #cw-main\'s class, its own label, and survives navigating ' \
     'to another tab (persisted in localStorage, not just in-memory page state)' do
    visit '/workers'
    expect(page).to have_css('[data-cw-wide-toggle]', text: '⛶ Full width')
    expect(page).to have_css('main#cw-main')
    expect(page).not_to have_css('main.cw-main--wide')

    find('[data-cw-wide-toggle]').click
    expect(page).to have_css('[data-cw-wide-toggle]', text: '⛶ Fixed width')
    expect(page).to have_css('main.cw-main--wide')

    visit '/overview'
    expect(page).to have_css('[data-cw-wide-toggle]', text: '⛶ Fixed width')
    expect(page).to have_css('main.cw-main--wide')

    find('[data-cw-wide-toggle]').click
    expect(page).to have_css('[data-cw-wide-toggle]', text: '⛶ Full width')
    expect(page).not_to have_css('main.cw-main--wide')
  end

  it 'the header never wraps onto multiple lines, even in a browser window narrower than its own ' \
     "content — like a desktop app's toolbar, the *page* scrolls horizontally instead, with no fixed " \
     'pixel minimum needed anywhere' do
    visit '/overview'
    original_height = page.evaluate_script("document.querySelector('header').getBoundingClientRect().height")

    page.current_window.resize_to(700, 700)
    # A real resize (and the reflow it triggers) is asynchronous in some
    # drivers — wait for the *full* effect (innerWidth updated *and* the
    # page actually grown a horizontal scrollbar for the header) rather
    # than asserting right after only the first part lands; under load
    # (the full suite, not just this file) there can be a real gap between
    # the two.
    wait_for(timeout: 5) do
      scrolls = page.evaluate_script('document.documentElement.scrollWidth') >
                page.evaluate_script('document.documentElement.clientWidth')
      page.evaluate_script('window.innerWidth') <= 700 && scrolls
    end

    resized_height = page.evaluate_script("document.querySelector('header').getBoundingClientRect().height")
    expect(resized_height).to eq(original_height) # single line, not wrapped onto a second/third row

    scroll_width = page.evaluate_script('document.documentElement.scrollWidth')

    # Regression test for a real bug: `#cw-main` used to keep shrinking to
    # match the narrow *viewport* even after the header had already forced
    # the page to scroll — both `header` and (bare `getBoundingClientRect`)
    # `#cw-main` reported the *same* clamped viewport width in that broken
    # state (their content simply overflowed past their own box, invisibly
    # to a plain width comparison between the two) — so the real assertion
    # is against `scrollWidth`, the actual overflowed canvas width, not
    # against each other. `scrollWidth` is an integer (rounded/ceiled per
    # spec) while `getBoundingClientRect().width` is a fractional CSS pixel
    # value, so a strict `==` between them can miss by a sub-pixel amount
    # even when they're layout-equivalent — `be_within` tolerates that
    # without also masking a real several-hundred-pixel "still clamped to
    # the viewport" failure.
    main_width = page.evaluate_script("document.getElementById('cw-main').getBoundingClientRect().width")
    expect(main_width).to be_within(1).of(scroll_width)
  ensure
    page.current_window.resize_to(1200, 800)
  end

  it "#cw-main's own wide content never drags the page's minimum width above the header's true " \
     "minimum — regression test for a real bug: #cw-main's own max-content contribution (a wide " \
     "table/card grid, capped by its own max-width) was feeding into body's min-width: max-content " \
     'calculation too, and — whenever it was bigger than the header\'s own minimum — won, freezing ' \
     "the header at #cw-main's width instead of letting it (and the page) keep tracking the window" do
    visit '/overview'
    # A deterministic 2000px-wide block inside #cw-main, independent of
    # whatever real content Overview happens to render (which — e.g. no
    # queues yet — may not reliably be wide enough on its own to have
    # reproduced the bug this guards against).
    page.execute_script(<<~JS)
      var wide = document.createElement('div');
      wide.style.width = '2000px';
      wide.style.height = '1px';
      document.getElementById('cw-main').appendChild(wide);
    JS

    # 1300px sits well above the header's own ~1090px true minimum — with
    # the bug, #cw-main's wide content (capped at its own 1480px max-width)
    # would still win and freeze the header there instead of at 1300.
    page.current_window.resize_to(1300, 800)
    wait_for(timeout: 5) { page.evaluate_script('window.innerWidth') <= 1300 }

    header_width = page.evaluate_script("document.querySelector('header').getBoundingClientRect().width")
    expect(header_width).to be_within(1).of(1300)
  ensure
    page.current_window.resize_to(1200, 800)
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
