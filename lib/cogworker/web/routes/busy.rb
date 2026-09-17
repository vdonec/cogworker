# frozen_string_literal: true

module Cogworker
  class Web
    module Routes
      # Lists live processes (ProcessSet) with quiet/stop actions, and the
      # in-flight jobs across all of them (WorkSet).
      module Busy
        CONTENT_ID = 'busy-content'

        module_function

        def registered(app)
          app.get('/busy') do
            content = Busy.render_content(request.script_name)
            if hx_request?
              content
            else
              Layout.wrap('Busy', Layout.poll_div(CONTENT_ID, request.script_name, 'busy', content),
                          script_name: request.script_name)
            end
          end

          app.post('/busy/quiet') { Busy.apply(self, &:quiet!) }
          app.post('/busy/stop') { Busy.apply(self, &:stop!) }
        end

        # Shared by the quiet/stop actions: perform the effect, then either
        # hand back the refreshed fragment (htmx swaps it into
        # #busy-content in place) or redirect back to the full page (a
        # plain, JS-less form submission).
        def apply(action)
          identity = action.params['identity']
          process = Cogworker::ProcessSet.new.find { |p| p.identity == identity }
          yield process if process

          if action.hx_request?
            render_content(action.request.script_name)
          else
            action.redirect(Layout.path(action.request.script_name, 'busy'))
          end
        end

        def render_content(script_name)
          quiet_path = Layout.path(script_name, 'busy/quiet')
          stop_path = Layout.path(script_name, 'busy/stop')
          # One `WorkSet` snapshot, reused for both tables below — the
          # process table's own "Busy" count used to come from
          # `p['busy']` (`Manager#busy_count`, only as fresh as this
          # process's *last heartbeat*, up to `Heartbeat::INTERVAL`
          # seconds stale) while the Workers table already read `WorkSet`
          # directly (updated in real time on every job start/finish, not
          # throttled by the heartbeat at all) — the two could visibly
          # disagree (e.g. "Busy: 1" next to 3 real Workers rows for that
          # same identity) whenever a job started or finished within the
          # last heartbeat interval. Deriving both from this single,
          # real-time snapshot means they can never disagree again.
          work_set = Cogworker::WorkSet.new.to_a
          busy_counts = work_set.each_with_object(Hash.new(0)) { |(identity, *), h| h[identity] += 1 }

          process_rows = Cogworker::ProcessSet.new.map do |p|
            [Layout.h(p.identity), Layout.time_tag(p['started_at']), memory_cell(p['rss_kb']),
             Layout.h(Array(p['queues']).join(', ')), busy_counts[p.identity], badge(p['quiet']),
             action_forms(quiet_path, stop_path, p.identity)]
          end
          work_rows = work_set.map do |identity, tid, work|
            [Layout.h(identity), Layout.h(tid), Layout.h(work.job['jid']), Layout.h(work.queue),
             Layout.h(work.job['class']), Layout.time_tag(work.run_at)]
          end
          Layout.table(%w[Identity StartedAt Memory Queues Busy Quiet Actions], process_rows,
                       empty_message: 'No worker processes are reporting in right now.') +
            Layout.section('Workers', Layout.table(%w[Identity Thread JID Queue Class RunAt], work_rows,
                                                   empty_message: 'No jobs in flight.'))
        end

        def badge(quiet)
          quiet == 'true' ? Layout.badge('quiet', variant: :warning) : Layout.badge('running', variant: :success)
        end

        # `rss_kb` is absent on any process whose heartbeat predates this
        # field (or that never measured cleanly — see
        # `Heartbeat#current_rss_kb`) — render "n/a" rather than "0M".
        def memory_cell(rss_kb)
          return 'n/a' unless rss_kb

          Layout.h(format('%.1fM', rss_kb.to_f / 1024))
        end

        def action_forms(quiet_path, stop_path, identity)
          hx_target = "##{CONTENT_ID}"
          Layout.form_button(quiet_path, 'identity', identity, 'quiet', hx_target: hx_target, variant: :warning) +
            Layout.form_button(stop_path, 'identity', identity, 'stop', hx_target: hx_target, variant: :danger)
        end
      end
    end
  end
end

Cogworker::Web.register(Cogworker::Web::Routes::Busy)
