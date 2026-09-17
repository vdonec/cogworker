# frozen_string_literal: true

module Cogworker
  class Web
    module Routes
      # Lists jobs that exhausted their retries, with delete and retry
      # (requeue) actions.
      module Dead
        CONTENT_ID = 'dead-content'

        module_function

        def registered(app)
          app.get('/dead') do
            content = Dead.render_content(request.script_name)
            if hx_request?
              content
            else
              Layout.wrap('Dead', Layout.poll_div(CONTENT_ID, request.script_name, 'dead', content),
                          script_name: request.script_name)
            end
          end

          app.post('/dead/delete') do
            Cogworker.config.redis { |c| c.zrem(RedisKeys::DEAD, params['raw']) }
            Dead.respond(self)
          end

          app.post('/dead/delete_all') do
            Cogworker.config.redis { |c| c.del(RedisKeys::DEAD) }
            Dead.respond(self)
          end

          # Puts the job back on its original queue for one more attempt —
          # same "graduate out of this ZSET, back onto cogworker:queue:<q>"
          # move `Routes::Retries#retry_now` does for `cogworker:retry`,
          # and `Cogworker::Scheduled#graduate` does for both `cogworker:
          # schedule`/`cogworker:retry`. `zrem` winning (not losing) is what
          # actually gates the requeue: without it, two browser tabs (or a
          # slow double-click) retrying the same entry at once could both
          # see it and each push a copy. NOTE: for a single (non-Array)
          # member, the `redis` gem's `#zrem` returns a **Boolean**, not the
          # raw `1`/`0` integer reply — `== 1` would always be false here
          # (`true == 1` is `false` in Ruby); check truthiness instead, the
          # same way `Cogworker::Scheduled#graduate`'s `next unless won` does.
          app.post('/dead/retry') do
            raw = params['raw']
            Cogworker.config.redis do |c|
              if c.zrem(RedisKeys::DEAD, raw)
                job = JSON.parse(raw)
                c.sadd(RedisKeys::QUEUES, job['queue'])
                c.lpush(RedisKeys.queue(job['queue']), raw)
              end
            end
            Dead.respond(self)
          end
        end

        # After an action, htmx gets the refreshed fragment swapped into
        # #dead-content in place; a plain form submission (no JS) falls back
        # to a normal redirect back to the full page.
        def respond(action)
          if action.hx_request?
            render_content(action.request.script_name)
          else
            action.redirect(Layout.path(action.request.script_name, 'dead'))
          end
        end

        def render_content(script_name)
          # Newest DiedAt first — `zrevrange` (`cogworker:dead`'s score is
          # the epoch it died at), not `zrange`.
          entries = Cogworker.config.redis { |c| c.zrevrange(RedisKeys::DEAD, 0, -1, withscores: true) }
          delete_path = Layout.path(script_name, 'dead/delete')
          retry_path = Layout.path(script_name, 'dead/retry')
          rows = entries.map do |raw, score|
            job = JSON.parse(raw)
            [job['jid'], Layout.h(job['class']), Layout.time_tag(score),
             Layout.form_button(retry_path, 'raw', raw, 'retry', hx_target: "##{CONTENT_ID}", variant: :primary),
             Layout.form_button(delete_path, 'raw', raw, 'delete', hx_target: "##{CONTENT_ID}", variant: :danger)]
          end
          delete_all_path = Layout.path(script_name, 'dead/delete_all')
          delete_all_button = Layout.action_button(delete_all_path, 'delete all', hx_target: "##{CONTENT_ID}",
                                                                                  variant: :danger)
          %(<div class="mb-3 flex justify-end">#{delete_all_button}</div>) +
            Layout.table(%w[JID Class DiedAt Retry Delete], rows, empty_message: 'No dead jobs.')
        end
      end
    end
  end
end

Cogworker::Web.register(Cogworker::Web::Routes::Dead)
