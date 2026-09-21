# frozen_string_literal: true

require 'cgi'
require 'fugit'
require 'json'

module Cogworker
  class Web
    module Routes
      # Lists every registered `config.periodic { |mgr| mgr.register(...) }`
      # entry and when it last/next fires, sourced entirely from Redis
      # (`periodic:schedule`/`periodic:last_slot:<pjid>`), not from any
      # in-process `Periodic::Manager` — those are only published once an
      # actual worker process's `Periodic::Ticker` has booted (see
      # `Ticker#publish_schedule!`), so a Web-UI-only process (no worker
      # ever started) shows the empty state here, same as Workers shows no
      # processes with no worker running.
      #
      # Named `Schedules` (not `Periodic`, the engine concept it reads —
      # `Cogworker::Periodic::*`) to match the "Relay" concept's tab name.
      # "Run now"/"Disable" are real actions (see `Ticker#disabled?`); "New
      # schedule" still isn't — adding one from here, not from `config.
      # periodic` in application code, would make Redis a second source of
      # truth for entries a worker restart's own `publish_schedule!` knows
      # nothing about, a real architecture question rather than a redesign
      # one.
      module Schedules
        CONTENT_ID = 'schedules-content'

        module_function

        def registered(app)
          app.get('/schedules') do
            content = Routes::Schedules.render_content(request.script_name, params)
            if hx_request?
              content
            else
              Layout.wrap('Schedules', Layout.poll_div(CONTENT_ID, request.script_name, 'schedules', content),
                          script_name: request.script_name)
            end
          end

          # Pushes this entry's class/args as one ordinary, independent job
          # right now — not tied to any cron slot, so it carries no
          # `periodic_pjid`/`periodic_slot` (unlike a real tick's own
          # `Ticker#enqueue`) and leaves the claim/`last_slot`/
          # `until_executed` running-lock bookkeeping in
          # `Periodic::ReleaseMiddleware` completely untouched.
          app.post('/schedules/:pjid/run_now') do
            Routes::Schedules.run_now(url_params('pjid'))
            Routes::Schedules.respond(self)
          end

          app.post('/schedules/:pjid/disable') do
            Cogworker.config.redis { |c| c.sadd(RedisKeys::PERIODIC_DISABLED, url_params('pjid')) }
            Routes::Schedules.respond(self)
          end

          app.post('/schedules/:pjid/enable') do
            Cogworker.config.redis { |c| c.srem(RedisKeys::PERIODIC_DISABLED, url_params('pjid')) }
            Routes::Schedules.respond(self)
          end
        end

        def run_now(pjid)
          raw = Cogworker.config.redis { |c| c.hget(RedisKeys::PERIODIC_SCHEDULE, pjid) }
          return unless raw

          entry = JSON.parse(raw)
          Cogworker::Client.push('class' => entry['class'], 'args' => entry['args'], 'retry' => entry['retry'])
        end

        # `q` (a plain query param, same full-page-link-carried-through-
        # actions pattern `Routes::Jobs`'s own search uses) survives both
        # response shapes here — an hx-swap re-render keeps whatever the
        # triggering form's own hidden `q` field carried (see
        # `actions_cell`), and a plain redirect carries it in the URL.
        def respond(action)
          if action.hx_request?
            render_content(action.request.script_name, action.params)
          else
            query = action.params['q'].to_s
            suffix = query.empty? ? '' : "?q=#{CGI.escape(query)}"
            action.redirect(Layout.path(action.request.script_name, "schedules#{suffix}"))
          end
        end

        def render_content(script_name, params)
          query = params['q'].to_s
          schedule = Cogworker.config.redis { |c| c.hgetall(RedisKeys::PERIODIC_SCHEDULE) }
          disabled = Cogworker.config.redis { |c| c.smembers(RedisKeys::PERIODIC_DISABLED) }
          entries = schedule.map { |pjid, raw| [pjid, JSON.parse(raw)] }
          filtered = entries.select { |_pjid, entry| matches_query?(entry, query) }
          rows = filtered.map { |pjid, entry| row_for(pjid, entry, script_name, disabled.include?(pjid), query) }
          table = Layout.table(%w[Class Cron Args NextRun LastRun Unique State Actions], rows,
                               empty_message: empty_message(entries.empty?))
          <<~HTML
            <div style="display: flex; flex-direction: column; gap: 16px;">
              #{page_header(script_name, query, filtered.size, entries.size)}
              #{table}
            </div>
          HTML
        end

        def matches_query?(entry, query)
          return true if query.strip.empty?

          haystack = "#{entry['class']}#{entry['cron']}#{entry['args']}".downcase
          haystack.include?(query.strip.downcase)
        end

        def empty_message(nothing_registered)
          return 'No schedules match that search.' unless nothing_registered

          'Nothing registered yet (no worker process has booted the periodic ' \
            'scheduler — periodic jobs are published to Redis by ' \
            'Periodic::Ticker on worker startup, not by the Web UI process).'
        end

        def page_header(script_name, query, shown_count, total_count)
          search_action = Layout.path(script_name, 'schedules')
          <<~HTML
            <div style="display: flex; align-items: flex-end; justify-content: space-between; gap: 16px; flex-wrap: wrap;">
              <div>
                <h2 style="margin: 0 0 4px;">Schedules</h2>
                <p class="text-muted" style="margin: 0; font-size: 13px;">#{shown_count} of #{total_count} shown</p>
              </div>
              <form method="get" action="#{search_action}">
                <input class="input" style="width: 240px;" type="search" name="q" placeholder="Search class, cron or args" value="#{Layout.h(query)}">
              </form>
            </div>
          HTML
        end

        def row_for(pjid, entry, script_name, disabled, query)
          [Layout.h(entry['class']), Layout.h(entry['cron']), Layout.h(entry['args'].to_json),
           next_run_tag(entry['cron'], disabled), last_run_tag(pjid), unique_cell(entry['unique']),
           state_tag(disabled), actions_cell(pjid, script_name, disabled, query)]
        end

        def next_run_tag(cron, disabled)
          return %(<span class="text-muted" style="font-style: italic;">disabled</span>) if disabled

          Layout.time_tag(Fugit::Cron.parse(cron)&.next_time(Time.now)&.to_t)
        rescue StandardError
          Layout.h('invalid cron')
        end

        def last_run_tag(pjid)
          last_slot = Cogworker.config.redis { |c| c.get(RedisKeys.periodic_last_slot(pjid)) }
          last_slot ? Layout.time_tag(last_slot.to_f) : %(<span class="text-muted" style="font-style: italic;">never</span>)
        end

        def unique_cell(unique)
          unique.nil? || unique.empty? ? '' : Layout.badge(unique, variant: :warning)
        end

        def state_tag(disabled)
          disabled ? Layout.badge('Disabled', variant: :warning) : Layout.badge('Enabled', variant: :success)
        end

        def actions_cell(pjid, script_name, disabled, query)
          run_now_path = Layout.path(script_name, "schedules/#{pjid}/run_now")
          run_now = action_button(run_now_path, 'run now', query, variant: :primary, icon: 'play')
          toggle = if disabled
                     enable_path = Layout.path(script_name, "schedules/#{pjid}/enable")
                     action_button(enable_path, 'enable', query, variant: :primary)
                   else
                     disable_path = Layout.path(script_name, "schedules/#{pjid}/disable")
                     action_button(disable_path, 'disable', query, variant: :warning, icon: 'pause')
                   end
          run_now + toggle
        end

        # Like `Layout.action_button`, but carrying the current search (`q`)
        # as a hidden field — so `respond` sees it in `action.params` and a
        # row action (run now/disable/enable) doesn't silently clear an
        # active search out from under the person who just clicked it.
        def action_button(path, label, query, variant:, icon: nil)
          if query.empty?
            return Layout.action_button(path, label, hx_target: "##{CONTENT_ID}", variant: variant, icon: icon)
          end

          classes = "btn #{Layout::BUTTON_VARIANTS.fetch(variant)}"
          <<~HTML
            <form style="display: inline;" hx-post="#{path}" hx-target="##{CONTENT_ID}" hx-swap="innerHTML" method="post" action="#{path}">
              <input type="hidden" name="q" value="#{Layout.h(query)}">
              <button type="submit" class="#{classes}" style="font-size: 13px; padding: 4px 10px;">#{Layout.icon_tag(icon)}#{Layout.h(label)}</button>
            </form>
          HTML
        end
      end
    end
  end
end

Cogworker::Web.register(Cogworker::Web::Routes::Schedules)
