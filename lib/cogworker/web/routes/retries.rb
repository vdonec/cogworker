# frozen_string_literal: true

module Cogworker
  class Web
    module Routes
      # Lists jobs currently scheduled for retry, with delete and
      # retry-now (skip the backoff) actions.
      module Retries
        CONTENT_ID = 'retries-content'

        module_function

        def registered(app)
          app.get('/retries') do
            content = Retries.render_content(request.script_name)
            if hx_request?
              content
            else
              Layout.wrap('Retries', Layout.poll_div(CONTENT_ID, request.script_name, 'retries', content),
                          script_name: request.script_name)
            end
          end

          app.post('/retries/delete') do
            Cogworker.config.redis { |c| c.zrem(RedisKeys::RETRY, params['raw']) }
            Retries.respond(self)
          end

          app.post('/retries/retry_now') do
            raw = params['raw']
            Cogworker.config.redis do |c|
              # For a single (non-Array) member, the `redis` gem's `#zrem`
              # returns a **Boolean**, not the raw `1`/`0` integer reply —
              # `== 1` is always false here (`true == 1` is `false` in
              # Ruby); check truthiness instead, matching
              # `Cogworker::Scheduled#graduate`'s `next unless won`.
              if c.zrem(RedisKeys::RETRY, raw)
                job = JSON.parse(raw)
                c.sadd(RedisKeys::QUEUES, job['queue'])
                c.lpush(RedisKeys.queue(job['queue']), raw)
              end
            end
            Retries.respond(self)
          end
        end

        # After an action, htmx gets the refreshed fragment swapped into
        # #retries-content in place; a plain form submission (no JS) falls
        # back to a normal redirect back to the full page.
        def respond(action)
          if action.hx_request?
            render_content(action.request.script_name)
          else
            action.redirect(Layout.path(action.request.script_name, 'retries'))
          end
        end

        def render_content(script_name)
          entries = Cogworker.config.redis { |c| c.zrange(RedisKeys::RETRY, 0, -1) }
          rows = entries.map do |raw|
            job = JSON.parse(raw)
            [job['jid'], Layout.h(job['class']), error_cell(job), delete_form(script_name, raw),
             retry_now_form(script_name, raw)]
          end
          Layout.table(%w[JID Class Error Delete RetryNow], rows, empty_message: 'No retries pending.')
        end

        def error_cell(job)
          <<~HTML
            <div class="font-mono text-xs text-red-700 dark:text-red-400">#{Layout.h(job['error_class'])}</div>
            <div class="text-xs text-gray-500 dark:text-gray-400 truncate max-w-xs">#{Layout.h(job['error_message'])}</div>
          HTML
        end

        def delete_form(script_name, raw)
          action = Layout.path(script_name, 'retries/delete')
          Layout.form_button(action, 'raw', raw, 'delete', hx_target: "##{CONTENT_ID}", variant: :danger)
        end

        def retry_now_form(script_name, raw)
          action = Layout.path(script_name, 'retries/retry_now')
          Layout.form_button(action, 'raw', raw, 'retry now', hx_target: "##{CONTENT_ID}", variant: :primary)
        end
      end
    end
  end
end

Cogworker::Web.register(Cogworker::Web::Routes::Retries)
