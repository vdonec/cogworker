# frozen_string_literal: true

module Cogworker
  class Web
    module Routes
      # Lists jobs pushed with `perform_in`/`perform_at`, still waiting for
      # their run-at time, with a delete action.
      module Scheduled
        CONTENT_ID = 'scheduled-content'

        module_function

        def registered(app)
          app.get('/scheduled') do
            content = Scheduled.render_content(request.script_name)
            if hx_request?
              content
            else
              Layout.wrap('Scheduled', Layout.poll_div(CONTENT_ID, request.script_name, 'scheduled', content),
                          script_name: request.script_name)
            end
          end

          app.post('/scheduled/delete') do
            Cogworker.config.redis { |c| c.zrem(RedisKeys::SCHEDULE, params['raw']) }
            if hx_request?
              Scheduled.render_content(request.script_name)
            else
              redirect Layout.path(request.script_name, 'scheduled')
            end
          end
        end

        def render_content(script_name)
          entries = Cogworker.config.redis { |c| c.zrange(RedisKeys::SCHEDULE, 0, -1, withscores: true) }
          delete_path = Layout.path(script_name, 'scheduled/delete')
          rows = entries.map do |raw, score|
            job = JSON.parse(raw)
            [job['jid'], Layout.h(job['class']), Layout.time_tag(score),
             Layout.form_button(delete_path, 'raw', raw, 'delete', hx_target: "##{CONTENT_ID}", variant: :danger)]
          end
          Layout.table(%w[JID Class RunAt Delete], rows, empty_message: 'Nothing scheduled.')
        end
      end
    end
  end
end

Cogworker::Web.register(Cogworker::Web::Routes::Scheduled)
