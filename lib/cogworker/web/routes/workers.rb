# frozen_string_literal: true

module Cogworker
  class Web
    module Routes
      # One card per live process (ProcessSet) — identity, active/quiet
      # state, served queues, live busy/concurrency + a load bar, memory,
      # heartbeat freshness, and quiet/stop actions — plus the existing
      # in-flight-jobs table (WorkSet) below, unchanged: the "Relay" concept
      # mock's own Workers cards assume one job per worker, which doesn't
      # fit this engine's multi-threaded-per-process model, so that table
      # (one row per actual busy thread, not per process) stays the more
      # honest place to look at what's actually running right now.
      module Workers
        CONTENT_ID = 'workers-content'
        SPARKLINE_HEIGHT_PX = 32

        module_function

        def registered(app)
          app.get('/workers') do
            content = Workers.render_content(request.script_name)
            if hx_request?
              content
            else
              Layout.wrap('Workers', Layout.poll_div(CONTENT_ID, request.script_name, 'workers', content) +
                                     Workers.sparkline_script,
                          script_name: request.script_name)
            end
          end

          app.post('/workers/quiet') { Workers.apply(self, &:quiet!) }
          app.post('/workers/resume') { Workers.apply(self, &:resume!) }
          app.post('/workers/stop') { Workers.apply(self, &:stop!) }

          # The header's own cluster status pill (`Layout.cluster_bar`,
          # shown on every page, not just this tab) polls this small
          # fragment independently — its own dedicated route, always just
          # the fragment.
          app.get('/workers/summary') { Layout.cluster_bar_content }

          # The header's "Pause intake"/"Resume intake" buttons
          # (`Layout.pause_intake_button`/`resume_intake_button`) — quiet/
          # resume every live process at once, the cluster-wide counterpart
          # to a single process's own quiet/resume card actions above.
          app.post('/workers/pause_all') { Workers.apply_to_all(self, &:quiet!) }
          app.post('/workers/resume_all') { Workers.apply_to_all(self, &:resume!) }
        end

        # Shared by the quiet/stop actions: perform the effect, then either
        # hand back the refreshed fragment (htmx swaps it into
        # #workers-content in place) or redirect back to the full page (a
        # plain, JS-less form submission).
        def apply(action)
          identity = action.params['identity']
          process = Cogworker::ProcessSet.new.find { |p| p.identity == identity }
          yield process if process

          if action.hx_request?
            render_content(action.request.script_name)
          else
            action.redirect(Layout.path(action.request.script_name, 'workers'))
          end
        end

        # Shared by the cluster-wide pause_all/resume_all actions: applies the
        # effect to every live process, then hands back the same fragment/
        # redirect shape `apply` above uses (the header's cluster bar for an
        # hx request, since that's the piece these two buttons actually sit
        # next to and refresh — not the Workers page fragment, unlike a
        # single-card action).
        def apply_to_all(action, &block)
          Cogworker::ProcessSet.new.each(&block)
          if action.hx_request?
            Layout.cluster_bar_content
          else
            action.redirect(Layout.path(action.request.script_name, 'workers'))
          end
        end

        def render_content(script_name)
          quiet_path = Layout.path(script_name, 'workers/quiet')
          resume_path = Layout.path(script_name, 'workers/resume')
          stop_path = Layout.path(script_name, 'workers/stop')
          processes = Cogworker::ProcessSet.new.to_a
          # One `WorkSet` snapshot, reused for both the cards' live busy
          # count and the in-flight jobs table below — see CLAUDE.md: the
          # process's own "busy" figure must come from this real-time
          # snapshot, not the heartbeat-published `p['busy']` (up to
          # `Heartbeat::INTERVAL` seconds stale), or the two can visibly
          # disagree on the same page.
          work_set = Cogworker::WorkSet.new.to_a
          busy_counts = work_set.each_with_object(Hash.new(0)) { |(identity, *), h| h[identity] += 1 }

          memory = Cogworker::MemoryHistory.series(processes.map(&:identity))

          cards = process_cards(processes, busy_counts, memory, quiet_path, resume_path, stop_path)

          work_rows = work_set.map do |identity, tid, work|
            [Layout.h(identity), Layout.h(tid), Layout.h(work.job['jid']), Layout.h(work.queue),
             Layout.h(work.job['class']), Layout.time_tag(work.run_at)]
          end
          jobs_table = Layout.table(%w[Identity Thread JID Queue Class RunAt], work_rows,
                                    empty_message: 'No jobs in flight.')

          # Same flex-column-with-gap wrapper `Routes::Jobs`/`Routes::
          # Overview` use for their own page_header — without it, the
          # header (a bare, unmargined `<div>`) sits flush against the
          # process cards right below it, a real bug once caught by hand.
          <<~HTML
            <div style="display: flex; flex-direction: column; gap: 16px;">
              #{page_header(processes)}
              #{cards}
              #{Layout.section('In-flight jobs', jobs_table)}
            </div>
          HTML
        end

        # The "Relay" concept mock's own summary line under the page title —
        # real counts, not the mock's fixed "12 processes · 96 threads": live
        # process count and the *configured* concurrency summed across them
        # (each process's own `concurrency` heartbeat field, its full thread
        # pool capacity — not `busy`, which is how many are working *right
        # now* and already has its own place in each card below). Cadence
        # comes straight from `Heartbeat::INTERVAL`, the one real source for
        # it, rather than a hardcoded "5s" that could drift from it.
        def page_header(processes)
          total_threads = processes.sum { |p| p['concurrency'].to_i }
          <<~HTML
            <div>
              <h2 style="margin: 0 0 4px;">Workers</h2>
              <p class="text-muted" style="margin: 0; font-size: 13px;">
                #{processes.size} #{processes.size == 1 ? 'process' : 'processes'} ·
                #{total_threads} #{total_threads == 1 ? 'thread' : 'threads'} ·
                heartbeat every #{Heartbeat::INTERVAL}s
              </p>
            </div>
          HTML
        end

        def process_cards(processes, busy_counts, memory, quiet_path, resume_path, stop_path)
          if processes.empty?
            return %(<p class="text-muted" style="font-size: 13px; font-style: italic;">No worker processes ) +
                   'are reporting in right now.</p>'
          end

          items = processes.map do |p|
            process_card(p, busy_counts[p.identity], memory[p.identity], quiet_path, resume_path, stop_path)
          end.join
          %(<div style="display: grid; grid-template-columns: repeat(auto-fill, minmax(320px, 1fr)); gap: 12px;">#{items}</div>)
        end

        def process_card(process, busy, memory_samples, quiet_path, resume_path, stop_path)
          concurrency = process['concurrency'].to_i
          pct = concurrency.positive? ? ((busy.to_f / concurrency) * 100).round : 0
          quiet = [true, 'true'].include?(process['quiet'])
          # A process already draining/exiting (mid-`stop!`) still reports
          # `quiet: true` on its last couple of heartbeats — but `resume!`
          # would be a no-op there (`Manager#stop!` already joined every
          # processor thread) and the card is about to disappear from
          # `ProcessSet` anyway, so showing "quiet" (not "resume") action
          # would just needlessly relabel a button no one can usefully press
          # in that narrow window. Not worth a separate stopping? signal over
          # the wire just to distinguish it.
          toggle_button = if quiet
                            Layout.form_button(resume_path, 'identity', process.identity, 'resume',
                                               hx_target: "##{CONTENT_ID}", variant: :success, icon: 'play')
                          else
                            Layout.form_button(quiet_path, 'identity', process.identity, 'quiet',
                                               hx_target: "##{CONTENT_ID}", variant: :warning, icon: 'pause')
                          end
          <<~HTML
            <div class="card elev-sm" style="gap: 10px; padding: 14px;">
              <div style="display: flex; align-items: center; justify-content: space-between; gap: 10px;">
                <span class="mono" style="font-size: 14px;">#{Layout.h(process.identity)}</span>
                #{state_tag(process['quiet'])}
              </div>
              <div style="display: flex; gap: 14px; font-size: 12px; color: var(--color-neutral-400); flex-wrap: wrap;">
                <span>#{Layout.h(Array(process['queues']).join(', '))}</span>
                <span>#{busy} / #{concurrency} busy</span>
                <span>#{memory_cell(process['rss_kb'])}</span>
                <span>#{beat_label(process.identity)}</span>
              </div>
              #{memory_sparkline(process.identity, memory_samples)}
              <div style="height: 4px; border-radius: 2px; background: var(--color-neutral-800); overflow: hidden;">
                <div style="height: 100%; border-radius: 2px; background: var(--color-accent); width: #{pct}%;"></div>
              </div>
              <div style="display: flex; align-items: center; justify-content: space-between; gap: 10px;">
                <span style="font-size: 12px; color: var(--color-neutral-500);">started #{Layout.time_tag(process['started_at'])}</span>
                <div style="display: flex; gap: 6px;">
                  #{toggle_button}
                  #{Layout.form_button(stop_path, 'identity', process.identity, 'stop', hx_target: "##{CONTENT_ID}", variant: :danger)}
                </div>
              </div>
            </div>
          HTML
        end

        def state_tag(quiet)
          if [true, 'true'].include?(quiet)
            Layout.badge('Quiet', variant: :warning)
          else
            Layout.badge('Active', variant: :success)
          end
        end

        # The last 24h of this process's RSS (MemoryHistory), always the
        # full 24h wide — one MemoryHistory slot per x position, broken
        # wherever a slot has no sample (before the process started, or
        # while Redis was away). An inline SVG rather than a Chart.js chart:
        # these cards are re-rendered by every htmx poll, and a Chart.js
        # instance per swap leaks (see CLAUDE.md's Overview charts).
        # Stretched to the card's width with `preserveAspectRatio="none"`,
        # so it draws only lines and fills (`non-scaling-stroke` keeps the
        # line's width) — no point markers, which that stretch would
        # distort; the hover marker and tooltip are HTML, positioned by
        # `sparkline_script` from the data attributes.
        def memory_sparkline(identity, slots)
          slots ||= Cogworker::MemoryHistory.series([identity])[identity]
          values = slots.map(&:last)
          low, high = sparkline_range(values.compact)
          <<~HTML
            <div class="cw-spark" data-cw-spark-id="#{Layout.h(identity)}" data-cw-spark="#{Layout.h(JSON.generate(values))}"
                 data-cw-spark-start="#{slots.first.first}" data-cw-spark-step="#{Cogworker::MemoryHistory::SAMPLE_SECONDS}"
                 data-cw-spark-min="#{low}" data-cw-spark-max="#{high}"
                 style="position: relative; height: #{SPARKLINE_HEIGHT_PX}px; cursor: crosshair; background: var(--color-bg); border-radius: 3px;">
              <span class="cw-spark-label" style="position: absolute; top: 3px; left: 6px; font-size: 10px; line-height: 1; color: var(--color-neutral-500); pointer-events: none;">Memory · 24h</span>
              <svg viewBox="0 0 100 100" preserveAspectRatio="none" aria-label="Memory, last 24 hours"
                   style="display: block; width: 100%; height: 100%; overflow: visible;">
                #{sparkline_segments(values, low, high)}
              </svg>
            </div>
          HTML
        end

        # One line + fill per run of consecutive slots that have a sample,
        # each point at its slot's center; a lone sample gets a short
        # horizontal stroke across its own slot, so it's still visible.
        def sparkline_segments(values, low, high)
          width = 100.0 / values.size
          runs = values.each_with_index.chunk_while { |(a, _), (b, _)| a.nil? == b.nil? }.reject { |run| run[0][0].nil? }
          runs.map do |run|
            points = run.map { |kb, i| [(i + 0.5) * width, (1 - ((kb - low) / (high - low))) * 100] }
            sparkline_segment(points, width)
          end.join
        end

        def sparkline_segment(points, width)
          if points.one?
            x, y = points.first
            points = [[x - (width / 2), y], [x + (width / 2), y]]
          end
          coords = points.map { |x, y| format('%<x>.2f,%<y>.2f', x: x, y: y) }.join(' ')
          area = format('%<x0>.2f,100 %<coords>s %<x1>.2f,100', x0: points.first[0], coords: coords, x1: points.last[0])
          <<~HTML
            <polygon points="#{area}" style="fill: var(--color-accent); opacity: 0.15;"></polygon>
            <polyline points="#{coords}" vector-effect="non-scaling-stroke" style="fill: none; stroke: var(--color-accent); stroke-width: 1.5;"></polyline>
          HTML
        end

        # A little headroom above and below, so the line never hugs the
        # card's edges; a flat series gets a range around its one value.
        def sparkline_range(values)
          return [0.0, 1.0] if values.empty?

          low = values.min.to_f
          high = values.max.to_f
          pad = [(high - low) * 0.1, 1024].max
          [(low - pad).clamp(0, nil), high + pad]
        end

        # Hover readout for every `.cw-spark` on the page: the sample
        # nearest the pointer, as a marker line + dot and a tooltip with
        # its value and (local) time, hiding the "Memory" label meanwhile.
        # Delegated from `document`, so it keeps working on cards htmx
        # swaps in; a poll that replaces the card under the pointer
        # re-shows the readout on the new one.
        def sparkline_script
          <<~HTML
            <script>
              (function () {
                var hover = null;
                function part(el, cls, css) {
                  var node = el.querySelector('.' + cls);
                  if (!node) {
                    node = document.createElement('div');
                    node.className = cls;
                    node.style.cssText = 'position: absolute; pointer-events: none; ' + css;
                    el.appendChild(node);
                  }
                  return node;
                }
                function label(el, visible) {
                  var node = el.querySelector('.cw-spark-label');
                  if (node) node.style.visibility = visible ? '' : 'hidden';
                }
                function hide(el) {
                  el.querySelectorAll('.cw-spark-line, .cw-spark-dot, .cw-spark-tip').forEach(function (n) { n.remove(); });
                  label(el, true);
                }
                function show(el, clientX) {
                  var values = JSON.parse(el.getAttribute('data-cw-spark'));
                  var start = parseInt(el.getAttribute('data-cw-spark-start'), 10);
                  var step = parseInt(el.getAttribute('data-cw-spark-step'), 10);
                  var lo = parseFloat(el.getAttribute('data-cw-spark-min'));
                  var hi = parseFloat(el.getAttribute('data-cw-spark-max'));
                  var rect = el.getBoundingClientRect();
                  label(el, false);
                  var frac = Math.min(Math.max((clientX - rect.left) / rect.width, 0), 1);
                  var i = Math.min(Math.floor(frac * values.length), values.length - 1);
                  var x = (i + 0.5) / values.length * rect.width;
                  var kb = values[i];
                  part(el, 'cw-spark-line', 'top: 0; bottom: 0; width: 1px; background: var(--color-neutral-500);').style.left = x + 'px';
                  var dot = part(el, 'cw-spark-dot', 'width: 6px; height: 6px; border-radius: 50%; margin: -3px 0 0 -3px; background: var(--color-accent);');
                  dot.style.display = kb === null ? 'none' : '';
                  dot.style.left = x + 'px';
                  if (kb !== null) dot.style.top = (1 - (kb - lo) / (hi - lo)) * rect.height + 'px';
                  var tip = part(el, 'cw-spark-tip', 'bottom: calc(100% + 4px); z-index: 10; white-space: nowrap; font-size: 11px; ' +
                    'padding: 3px 6px; border-radius: 4px; background: var(--color-surface); color: var(--color-text); ' +
                    'box-shadow: var(--shadow-md); border: 1px solid var(--color-neutral-800);');
                  var at = new Date((start + i * step) * 1000);
                  var when = window.cogworkerFormatTime ? window.cogworkerFormatTime(at) : at.toLocaleString();
                  tip.textContent = (kb === null ? 'no data' : (kb / 1024).toFixed(1) + 'M') + ' · ' + when;
                  tip.style.left = x + 'px';
                  tip.style.transform = 'translateX(-' + (frac * 100) + '%)';
                }
                function find(id) {
                  var all = document.querySelectorAll('.cw-spark');
                  for (var i = 0; i < all.length; i++) if (all[i].getAttribute('data-cw-spark-id') === id) return all[i];
                  return null;
                }
                document.addEventListener('mousemove', function (evt) {
                  var el = evt.target.closest && evt.target.closest('.cw-spark');
                  if (hover && (!el || el.getAttribute('data-cw-spark-id') !== hover.id)) {
                    var old = find(hover.id);
                    if (old) hide(old);
                    hover = null;
                  }
                  if (!el) return;
                  hover = { id: el.getAttribute('data-cw-spark-id'), x: evt.clientX };
                  show(el, evt.clientX);
                });
                document.addEventListener('htmx:afterSwap', function () {
                  if (!hover) return;
                  var el = find(hover.id);
                  if (el) show(el, hover.x);
                });
              })();
            </script>
          HTML
        end

        # `rss_kb` is absent on any process whose heartbeat predates this
        # field (or that never measured cleanly — see
        # `Heartbeat#current_rss_kb`) — render "n/a" rather than "0M".
        def memory_cell(rss_kb)
          return 'n/a' unless rss_kb

          format('%.1fM', rss_kb.to_f / 1024)
        end

        # No stored "last heartbeat at" field — derived instead from the
        # process key's own remaining Redis TTL (refreshed to
        # `Heartbeat::TTL` on every beat), which is already exactly the
        # data needed for this and avoids adding a redundant timestamp
        # field to the heartbeat payload.
        def beat_label(identity)
          ttl = Cogworker.config.redis { |c| c.ttl(RedisKeys.process(identity)) }
          return 'beat unknown' if ttl.negative?

          "beat #{[Heartbeat::TTL - ttl, 0].max}s ago"
        end
      end
    end
  end
end

Cogworker::Web.register(Cogworker::Web::Routes::Workers)
