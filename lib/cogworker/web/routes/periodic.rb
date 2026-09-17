# frozen_string_literal: true

require 'fugit'
require 'json'

module Cogworker
  class Web
    module Routes
      # Read-only: lists every registered `config.periodic { |mgr|
      # mgr.register(...) }` entry and when it last/next fires. Sourced
      # entirely from Redis (`periodic:schedule`/`periodic:last_slot:<pjid>`),
      # not from any in-process `Periodic::Manager` — those are only
      # published once an actual worker process's `Periodic::Ticker` has
      # booted (see `Ticker#publish_schedule!`), so a Web-UI-only process
      # (no worker ever started) shows the empty state here, same as Busy
      # shows no processes with no worker running.
      module Periodic
        CONTENT_ID = 'periodic-content'

        module_function

        def registered(app)
          app.get('/periodic') do
            content = Routes::Periodic.render_content
            if hx_request?
              content
            else
              Layout.wrap('Periodic', Layout.poll_div(CONTENT_ID, request.script_name, 'periodic', content),
                          script_name: request.script_name)
            end
          end
        end

        def render_content
          schedule = Cogworker.config.redis { |c| c.hgetall(RedisKeys::PERIODIC_SCHEDULE) }
          rows = schedule.map { |pjid, raw| row_for(pjid, JSON.parse(raw)) }
          Layout.table(%w[Class Cron Args NextRun LastRun Unique], rows,
                       empty_message: 'Nothing registered yet (no worker process has booted the periodic ' \
                                      'scheduler — periodic jobs are published to Redis by ' \
                                      'Periodic::Ticker on worker startup, not by the Web UI process).')
        end

        def row_for(pjid, entry)
          [Layout.h(entry['class']), Layout.h(entry['cron']), Layout.h(entry['args'].to_json),
           next_run_tag(entry['cron']), last_run_tag(pjid), unique_cell(entry['unique'])]
        end

        def next_run_tag(cron)
          Layout.time_tag(Fugit::Cron.parse(cron)&.next_time(Time.now)&.to_t)
        rescue StandardError
          Layout.h('invalid cron')
        end

        def last_run_tag(pjid)
          last_slot = Cogworker.config.redis { |c| c.get(RedisKeys.periodic_last_slot(pjid)) }
          last_slot ? Layout.time_tag(last_slot.to_f) : %(<span class="text-gray-400 italic">never</span>)
        end

        def unique_cell(unique)
          unique.nil? || unique.empty? ? '' : Layout.badge(unique, variant: :warning)
        end
      end
    end
  end
end

Cogworker::Web.register(Cogworker::Web::Routes::Periodic)
