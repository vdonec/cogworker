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

        module_function

        def registered(app)
          app.get('/workers') do
            content = Workers.render_content(request.script_name)
            if hx_request?
              content
            else
              Layout.wrap('Workers', Layout.poll_div(CONTENT_ID, request.script_name, 'workers', content),
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

          cards = process_cards(processes, busy_counts, quiet_path, resume_path, stop_path)

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

        def process_cards(processes, busy_counts, quiet_path, resume_path, stop_path)
          if processes.empty?
            return %(<p class="text-muted" style="font-size: 13px; font-style: italic;">No worker processes ) +
                   'are reporting in right now.</p>'
          end

          items = processes.map do |p|
            process_card(p, busy_counts[p.identity], quiet_path, resume_path, stop_path)
          end.join
          %(<div style="display: grid; grid-template-columns: repeat(auto-fill, minmax(320px, 1fr)); gap: 12px;">#{items}</div>)
        end

        def process_card(process, busy, quiet_path, resume_path, stop_path)
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
