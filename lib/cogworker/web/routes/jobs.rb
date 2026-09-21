# frozen_string_literal: true

require 'cgi'
require 'json'

module Cogworker
  class Web
    module Routes
      # One filterable, searchable table across every individual job
      # instance — enqueued, running, scheduled (`perform_in`/`perform_at`),
      # retrying, and dead — replacing the four separate `Routes::Queues`*/
      # `Retries`/`Scheduled`/`Dead` tabs' own per-status tables with one
      # list plus a status filter, and a click-through detail panel (args,
      # retry timeline, last error, actions) in place of `Routes::Dead`'s
      # flat rows. (*`Routes::Queues`' own queue-level browsing survives
      # separately, as `Routes::Overview` layout B — this tab is the
      # cross-queue, cross-status view; the two overlap a little on purpose,
      # the same way a real Sidekiq-style admin wants both "what's in this
      # queue" and "find this one job wherever it is".)
      #
      # `?status=`/`?q=`/`?selected=` are plain query params, read fresh on
      # every request and carried through the self-poll and every action's
      # redirect (`query_string`) — the same full-page-link pattern
      # `Routes::Overview`'s layout switcher and `Routes::History`'s status
      # filter already use, not client-side state.
      module Jobs
        CONTENT_ID = 'jobs-content'
        STATUSES = %w[All Enqueued Running Scheduled Retrying Dead].freeze
        # `Cogworker::Attempts` itself already caps storage at `MAX_ENTRIES`
        # (25) — this is a *second*, smaller cap on top of that, just for
        # this compact sidebar panel: showing all 25 here would make the
        # panel far taller than the row list next to it. The full trail
        # (still capped at 25, but the same 25 either way) is one click
        # away via the History link below, not lost.
        ATTEMPTS_DISPLAY_LIMIT = 5
        TAG_CLASS = { 'Enqueued' => 'tag-neutral', 'Running' => 'tag-accent', 'Scheduled' => 'tag-accent-2',
                      'Retrying' => 'tag-warning', 'Dead' => 'tag-danger' }.freeze

        module_function

        def registered(app)
          app.get('/jobs') do
            content = Jobs.render_content(request.script_name, params)
            if hx_request?
              content
            else
              Layout.wrap('Jobs',
                          Layout.poll_div(CONTENT_ID, request.script_name, "jobs#{Jobs.query_string(params)}",
                                          content), script_name: request.script_name)
            end
          end

          app.post('/jobs/enqueued/delete') do
            Cogworker::Queue.new(params['queue']).delete(params['raw'])
            Jobs.respond(self, params)
          end

          app.post('/jobs/scheduled/delete') do
            Cogworker.config.redis { |c| c.zrem(RedisKeys::SCHEDULE, params['raw']) }
            Jobs.respond(self, params)
          end

          app.post('/jobs/retrying/delete') do
            raw = params['raw']
            Cogworker.config.redis { |c| c.zrem(RedisKeys::RETRY, raw) }
            Cogworker::Attempts.clear(JSON.parse(raw)['jid'])
            Jobs.respond(self, params)
          end

          # Same "graduate back onto its queue" move `Routes::Dead#retry`/
          # `Cogworker::Scheduled#graduate` make — `zrem` winning (not
          # losing) gates it so two tabs retrying the same entry at once
          # can't both requeue it; the `redis` gem's `#zrem` returns a
          # **Boolean** for a single member, so this checks truthiness, not
          # `== 1` (`true == 1` is `false` in Ruby).
          app.post('/jobs/retrying/retry_now') do
            raw = params['raw']
            Cogworker.config.redis do |c|
              if c.zrem(RedisKeys::RETRY, raw)
                job = JSON.parse(raw)
                c.sadd(RedisKeys::QUEUES, job['queue'])
                c.lpush(RedisKeys.queue(job['queue']), raw)
              end
            end
            Jobs.respond(self, params)
          end

          app.post('/jobs/dead/delete') do
            raw = params['raw']
            Cogworker.config.redis { |c| c.zrem(RedisKeys::DEAD, raw) }
            Cogworker::Attempts.clear(JSON.parse(raw)['jid'])
            Jobs.respond(self, params)
          end

          app.post('/jobs/dead/delete_all') do
            jids = Cogworker.config.redis { |c| c.zrange(RedisKeys::DEAD, 0, -1) }.map { |raw| JSON.parse(raw)['jid'] }
            Cogworker.config.redis { |c| c.del(RedisKeys::DEAD) }
            jids.each { |jid| Cogworker::Attempts.clear(jid) }
            Jobs.respond(self, params)
          end

          app.post('/jobs/dead/retry') do
            raw = params['raw']
            Cogworker.config.redis do |c|
              if c.zrem(RedisKeys::DEAD, raw)
                job = JSON.parse(raw)
                c.sadd(RedisKeys::QUEUES, job['queue'])
                c.lpush(RedisKeys.queue(job['queue']), raw)
              end
            end
            Jobs.respond(self, params)
          end

          # Moves this one entry's score on its own ZSET — "run sooner" or
          # "push back a flaky retry" — without touching anything else about
          # it (attempt count, error, args all carry over unchanged, same
          # raw payload). `zrem` winning first (not losing) guards this the
          # same way every other per-entry action here does: if the entry
          # was deleted/retried by another tab in between, there's nothing
          # left to reschedule, so it's silently skipped rather than
          # resurrecting a stale copy.
          app.post('/jobs/retrying/reschedule') do
            Jobs.reschedule(RedisKeys::RETRY, params['raw'], params['minutes'])
            Jobs.respond(self, params)
          end

          app.post('/jobs/scheduled/reschedule') do
            Jobs.reschedule(RedisKeys::SCHEDULE, params['raw'], params['minutes'])
            Jobs.respond(self, params)
          end
        end

        # A relative offset ("run in N minutes"), not an absolute date/time
        # picker: a `datetime-local` input reports the *browser's* local
        # wall-clock with no timezone attached, and correctly converting
        # that back to the server's UTC epoch needs its own bit of
        # client-side JS (`new Date(value).getTime()`) — a real, tested
        # moving part for what this is mostly used for (nudge a flaky retry
        # sooner or later by a few minutes). A plain relative number needs
        # none of that: the server computes the absolute score itself, with
        # no timezone to get wrong.
        RESCHEDULE_MAX_MINUTES = 10_080 # 1 week — a sane upper bound on the input, not a real limit elsewhere

        def reschedule(zset_key, raw, minutes_param)
          minutes = minutes_param.to_i.clamp(1, RESCHEDULE_MAX_MINUTES)
          Cogworker.config.redis do |c|
            c.zadd(zset_key, Time.now.to_f + (minutes * 60), raw) if c.zrem(zset_key, raw)
          end
        end

        # After an action, htmx gets the refreshed fragment swapped into
        # #jobs-content in place, keeping the same filter/search/selection;
        # a plain form submission (no JS) falls back to a normal redirect
        # to that same URL.
        def respond(action, params)
          if action.hx_request?
            render_content(action.request.script_name, params)
          else
            action.redirect(Layout.path(action.request.script_name, "jobs#{query_string(params)}"))
          end
        end

        def query_string(params)
          status = STATUSES.include?(params['status']) ? params['status'] : 'All'
          q = params['q'].to_s
          selected = params['selected'].to_s
          parts = []
          parts << "status=#{CGI.escape(status)}" unless status == 'All'
          parts << "q=#{CGI.escape(q)}" unless q.empty?
          parts << "selected=#{CGI.escape(selected)}" unless selected.empty?
          parts.empty? ? '' : "?#{parts.join('&')}"
        end

        def render_content(script_name, params)
          status = STATUSES.include?(params['status']) ? params['status'] : 'All'
          query = params['q'].to_s
          rows = all_rows
          filtered = rows.select { |r| status == 'All' || r[:status] == status }
          filtered = filtered.select { |r| matches_query?(r, query) } unless query.strip.empty?
          filtered.sort_by! { |r| -(r[:at] || 0) }

          selected = rows.find { |r| r[:jid] == params['selected'] }

          <<~HTML
            <div style="display: flex; flex-direction: column; gap: 16px;">
              #{page_header(script_name, status, query, filtered.size, rows.size)}
              <div style="display: grid; grid-template-columns: minmax(0, 1fr) #{selected ? 'minmax(320px, 400px)' : '0px'}; gap: 16px; align-items: start;">
                #{jobs_table(filtered, script_name, params)}
                #{selected ? detail_panel(selected, script_name, params) : ''}
              </div>
            </div>
          HTML
        end

        def matches_query?(row, query)
          haystack = "#{row[:klass]}#{row[:jid]}#{row[:args]}".downcase
          haystack.include?(query.strip.downcase)
        end

        def page_header(script_name, status, query, shown_count, total_count)
          filters = STATUSES.map do |s|
            checked = s == status ? ' checked' : ''
            href = Layout.path(script_name, "jobs#{query_string('status' => s, 'q' => query)}")
            %(<label class="seg-opt"><input type="radio" name="status"#{checked} onchange="location.href='#{href}'">#{Layout.h(s)}</label>)
          end.join
          search_action = Layout.path(script_name, 'jobs')
          <<~HTML
            <div style="display: flex; align-items: flex-end; justify-content: space-between; gap: 16px; flex-wrap: wrap;">
              <div>
                <h2 style="margin: 0 0 4px;">Jobs</h2>
                <p class="text-muted" style="margin: 0; font-size: 13px;">#{shown_count} of #{total_count} shown</p>
              </div>
              <div style="display: flex; align-items: center; gap: 10px; flex-wrap: wrap;">
                <form method="get" action="#{search_action}">
                  <input type="hidden" name="status" value="#{Layout.h(status)}">
                  <input class="input" style="width: 240px;" type="search" name="q" placeholder="Search class, jid or args" value="#{Layout.h(query)}">
                </form>
                <div class="seg">#{filters}</div>
              </div>
            </div>
          HTML
        end

        def jobs_table(rows, script_name, params)
          table_rows = rows.map do |r|
            href = Layout.path(script_name, "jobs#{query_string(params.merge('selected' => r[:jid]))}")
            job_cell = <<~HTML
              <a href="#{href}" style="text-decoration: none; color: inherit; display: block;">
                <div class="mono" style="font-size: 14px;">#{Layout.h(r[:klass])}</div>
                <div class="mono" style="font-size: 11px; color: var(--color-neutral-500);">#{Layout.h(r[:jid])}</div>
              </a>
            HTML
            [job_cell, Layout.h(r[:queue]), status_tag(r[:status]),
             Layout.h(r[:attempt]), r[:next_action] ? Layout.time_tag(r[:next_action]) : '—',
             r[:at] ? Layout.time_tag(r[:at]) : '—', row_actions(r, script_name, params)]
          end
          Layout.table(%w[Job Queue Status Attempt NextRun At Actions], table_rows,
                       empty_message: 'No jobs match this view.')
        end

        # Finer-grained than `Layout.badge`'s 4 semantic variants (success/
        # warning/danger/default): Running/Scheduled get their own accent/
        # accent-2 tint rather than falling back to neutral, so a glance at
        # the Status column tells "in flight" and "not due yet" apart from
        # a plain "waiting" enqueued row.
        def status_tag(status)
          %(<span class="tag #{TAG_CLASS.fetch(status, 'tag-neutral')}">#{Layout.h(status)}</span>)
        end

        def row_actions(row, script_name, params)
          case row[:source]
          when :enqueued
            delete_button('enqueued', script_name, row, params, extra: { 'queue' => row[:queue] })
          when :scheduled
            delete_button('scheduled', script_name, row, params)
          when :retrying
            retry_now_button('retrying', script_name, row, params) + delete_button('retrying', script_name, row,
                                                                                    params)
          when :dead
            retry_button('dead', script_name, row, params) + delete_button('dead', script_name, row, params)
          else
            ''
          end
        end

        def delete_button(bucket, script_name, row, params, extra: {})
          action = Layout.path(script_name, "jobs/#{bucket}/delete")
          form_with_extra(action, 'raw', row[:raw], 'delete', params, variant: :danger, icon: 'trash', extra: extra)
        end

        def retry_now_button(bucket, script_name, row, params)
          action = Layout.path(script_name, "jobs/#{bucket}/retry_now")
          form_with_extra(action, 'raw', row[:raw], 'retry now', params, variant: :primary, icon: 'arrow-clockwise',
                                                                          extra: {})
        end

        def retry_button(bucket, script_name, row, params)
          action = Layout.path(script_name, "jobs/#{bucket}/retry")
          form_with_extra(action, 'raw', row[:raw], 'retry', params, variant: :primary, icon: 'arrow-clockwise',
                                                                      extra: {})
        end

        # `Layout.form_button` only carries one hidden field. Every action
        # here needs more: `status`/`q`/`selected` (so the fragment/redirect
        # `respond` sends back preserves the view the user was looking at —
        # these forms are the only way that state reaches the POST at all,
        # since it isn't in the URL a plain form submits to) plus, for an
        # enqueued-job delete, `queue` (`Queue#delete` isn't keyed off the
        # raw payload alone the way the ZSETs are).
        def form_with_extra(action, hidden_name, hidden_value, label, params, variant:, icon: nil, extra:)
          hidden = extra.merge('status' => params['status'].to_s, 'q' => params['q'].to_s,
                                'selected' => params['selected'].to_s)
          hidden_inputs = hidden.map { |k, v| %(<input type="hidden" name="#{k}" value="#{Layout.h(v)}">) }.join
          classes = "btn #{Layout::BUTTON_VARIANTS.fetch(variant)}"
          <<~HTML
            <form style="display: inline;" hx-post="#{action}" hx-target="##{CONTENT_ID}" hx-swap="innerHTML" method="post" action="#{action}">
              <input type="hidden" name="#{hidden_name}" value="#{Layout.h(hidden_value)}">
              #{hidden_inputs}
              <button type="submit" class="#{classes}" style="font-size: 13px; padding: 4px 10px;">#{Layout.icon_tag(icon)}#{Layout.h(label)}</button>
            </form>
          HTML
        end

        def detail_panel(row, script_name, params)
          close_href = Layout.path(script_name, "jobs#{query_string(params.merge('selected' => nil))}")
          <<~HTML
            <aside style="background: var(--color-surface); border-radius: var(--radius-md); box-shadow: var(--shadow-md); padding: 16px 18px; display: flex; flex-direction: column; gap: 14px; position: sticky; top: 84px;">
              <div style="display: flex; align-items: flex-start; justify-content: space-between; gap: 10px;">
                <div>
                  <div class="mono" style="font-size: 16px;">#{Layout.h(row[:klass])}</div>
                  <div class="mono" style="font-size: 11px; color: var(--color-neutral-500); margin-top: 2px;">#{Layout.h(row[:jid])}</div>
                </div>
                <a href="#{close_href}" class="btn btn-icon btn-secondary" aria-label="Close"><i class="ph ph-x"></i></a>
              </div>
              <div style="display: flex; flex-wrap: wrap; gap: 6px;">
                #{status_tag(row[:status])}
                <span class="tag tag-neutral">#{Layout.h(row[:queue])}</span>
                <span class="tag tag-outline">attempt #{Layout.h(row[:attempt])}</span>
              </div>
              <div>
                <div style="font-size: 11px; letter-spacing: 0.08em; text-transform: uppercase; color: var(--color-neutral-500); margin-bottom: 6px;">Arguments</div>
                <pre class="mono" style="margin: 0; font-size: 12px; line-height: 1.6; background: var(--color-bg); border: 1px solid var(--color-divider); border-radius: var(--radius-sm); padding: 10px; overflow-x: auto;">#{Layout.h(JSON.pretty_generate(row[:args]))}</pre>
              </div>
              #{attempts_section(row, script_name)}
              #{last_error_section(row)}
              #{reschedule_section(row, script_name, params)}
              <div style="display: flex; gap: 8px; flex-wrap: wrap;">
                #{row_actions(row, script_name, params)}
              </div>
            </aside>
          HTML
        end

        def reschedule_section(row, script_name, params)
          return '' unless %w[Retrying Scheduled].include?(row[:status])

          action = Layout.path(script_name, "jobs/#{row[:source]}/reschedule")
          hidden = { 'status' => params['status'].to_s, 'q' => params['q'].to_s,
                     'selected' => params['selected'].to_s }
          hidden_inputs = hidden.map { |k, v| %(<input type="hidden" name="#{k}" value="#{Layout.h(v)}">) }.join
          <<~HTML
            <div>
              <div style="font-size: 11px; letter-spacing: 0.08em; text-transform: uppercase; color: var(--color-neutral-500); margin-bottom: 6px;">Reschedule</div>
              <form style="display: flex; align-items: center; gap: 8px; flex-wrap: wrap;" hx-post="#{action}" hx-target="##{CONTENT_ID}" hx-swap="innerHTML" method="post" action="#{action}">
                <input type="hidden" name="raw" value="#{Layout.h(row[:raw])}">
                #{hidden_inputs}
                <span style="font-size: 13px; color: var(--color-neutral-400);">run in</span>
                <input class="input" type="number" name="minutes" min="1" max="#{RESCHEDULE_MAX_MINUTES}" value="5" style="width: 72px;">
                <span style="font-size: 13px; color: var(--color-neutral-400);">minutes</span>
                <button type="submit" class="btn btn-secondary" style="font-size: 13px; padding: 4px 10px;">#{Layout.icon_tag('clock-countdown')}reschedule</button>
              </form>
            </div>
          HTML
        end

        def attempts_section(row, script_name)
          return '' unless %w[Retrying Dead].include?(row[:status])

          attempts = Cogworker::Attempts.for(row[:jid]).reverse
          return '' if attempts.empty?

          shown = attempts.first(ATTEMPTS_DISPLAY_LIMIT)
          items = shown.map do |a|
            dot = a['outcome'] == 'dead' ? 'var(--color-danger)' : 'var(--color-warning)'
            <<~HTML
              <div style="display: grid; grid-template-columns: 18px minmax(0, 1fr); gap: 10px;">
                <div style="display: flex; flex-direction: column; align-items: center;">
                  <span style="width: 9px; height: 9px; border-radius: 50%; background: #{dot}; margin-top: 5px;"></span>
                </div>
                <div style="padding-bottom: 12px;">
                  <div style="font-size: 13px;">Attempt #{a['attempt']} · #{a['outcome'] == 'dead' ? 'moved to dead set' : 'failed'}</div>
                  <div style="font-size: 12px; color: var(--color-neutral-500);">#{Layout.h(Time.at(a['failed_at']).utc.strftime(Web.time_format))} · #{Layout.h(a['error_class'])}: #{Layout.h(a['error_message'])}</div>
                </div>
              </div>
            HTML
          end.join
          <<~HTML
            <div>
              <div style="display: flex; align-items: center; justify-content: space-between; gap: 8px; margin-bottom: 8px;">
                <div style="font-size: 11px; letter-spacing: 0.08em; text-transform: uppercase; color: var(--color-neutral-500);">
                  Retry history#{" (last #{shown.size} of #{attempts.size})" if attempts.size > shown.size}
                </div>
                #{history_link(row, script_name)}
              </div>
              <div style="display: flex; flex-direction: column;">#{items}</div>
            </div>
          HTML
        end

        # Full timeline for this job — not just its failures (`Cogworker::
        # Attempts` above, capped to `ATTEMPTS_DISPLAY_LIMIT` here on top of
        # its own storage cap) but every completed run, success included,
        # since a retried job keeps its original jid across every attempt.
        def history_link(row, script_name)
          href = Layout.path(script_name, "history?jid=#{CGI.escape(row[:jid])}")
          %(<a href="#{href}" style="font-size: 12px; white-space: nowrap;">view in History</a>)
        end

        def last_error_section(row)
          return '' unless row[:error_class]

          <<~HTML
            <div>
              <div style="font-size: 11px; letter-spacing: 0.08em; text-transform: uppercase; color: var(--color-neutral-500); margin-bottom: 6px;">Last error</div>
              <pre class="mono" style="margin: 0; font-size: 12px; line-height: 1.6; background: var(--color-bg); border: 1px solid color-mix(in srgb, var(--color-danger) 35%, transparent); border-radius: var(--radius-sm); padding: 10px; overflow-x: auto; color: var(--color-danger-300);">#{Layout.h(row[:error_class])}: #{Layout.h(row[:error_message])}</pre>
            </div>
          HTML
        end

        def all_rows
          enqueued_rows + running_rows + scheduled_rows + retrying_rows + dead_rows
        end

        def enqueued_rows
          Cogworker.config.redis { |c| c.smembers(RedisKeys::QUEUES) }.sort.flat_map do |queue_name|
            Cogworker::Queue.new(queue_name).map do |r|
              { jid: r.jid, klass: r.klass, queue: r.queue, status: 'Enqueued', attempt: '—', next_action: nil,
                at: r.item['created_at'] || r.item['enqueued_at'], args: r.args, error_class: nil,
                error_message: nil, raw: r.value, source: :enqueued }
            end
          end
        end

        def running_rows
          Cogworker::WorkSet.new.map do |_identity, _tid, work|
            job = work.job
            { jid: job['jid'], klass: job['class'], queue: work.queue, status: 'Running',
              attempt: (job['retry_count'].to_i + 1).to_s, next_action: nil, at: work.run_at, args: job['args'],
              error_class: nil, error_message: nil, raw: nil, source: :running }
          end
        end

        def scheduled_rows
          entries = Cogworker.config.redis { |c| c.zrange(RedisKeys::SCHEDULE, 0, -1, withscores: true) }
          entries.map do |raw, score|
            job = JSON.parse(raw)
            { jid: job['jid'], klass: job['class'], queue: job['queue'], status: 'Scheduled', attempt: '—',
              next_action: score, at: job['created_at'], args: job['args'], error_class: nil, error_message: nil,
              raw: raw, source: :scheduled }
          end
        end

        def retrying_rows
          entries = Cogworker.config.redis { |c| c.zrange(RedisKeys::RETRY, 0, -1, withscores: true) }
          entries.map do |raw, score|
            job = JSON.parse(raw)
            { jid: job['jid'], klass: job['class'], queue: job['queue'], status: 'Retrying',
              attempt: "#{job['retry_count'].to_i} of #{JobUtil.max_retries(job)}", next_action: score,
              at: job['failed_at'] || job['created_at'], args: job['args'], error_class: job['error_class'],
              error_message: job['error_message'], raw: raw, source: :retrying }
          end
        end

        def dead_rows
          entries = Cogworker.config.redis { |c| c.zrevrange(RedisKeys::DEAD, 0, -1, withscores: true) }
          entries.map do |raw, score|
            job = JSON.parse(raw)
            { jid: job['jid'], klass: job['class'], queue: job['queue'], status: 'Dead',
              attempt: "#{job['retry_count'].to_i} of #{JobUtil.max_retries(job)}", next_action: nil, at: score,
              args: job['args'], error_class: job['error_class'], error_message: job['error_message'], raw: raw,
              source: :dead }
          end
        end
      end
    end
  end
end

Cogworker::Web.register(Cogworker::Web::Routes::Jobs)
