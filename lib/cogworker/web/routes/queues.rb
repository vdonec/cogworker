# frozen_string_literal: true

module Cogworker
  class Web
    module Routes
      # Lists every known queue with its size/latency, and a per-queue drill
      # down page listing that queue's pending jobs.
      module Queues
        CONTENT_ID = 'queues-content'
        QUEUE_CONTENT_ID = 'queue-content'

        module_function

        def registered(app)
          app.get('/queues') do
            content = Queues.render_content(request.script_name)
            if hx_request?
              content
            else
              Layout.wrap('Queues', Layout.poll_div(CONTENT_ID, request.script_name, 'queues', content),
                          script_name: request.script_name)
            end
          end

          app.get('/queues/:name') do
            name = url_params('name')
            content = Queues.render_queue_content(name, request.script_name)
            if hx_request?
              content
            else
              Layout.wrap("Queue: #{Layout.h(name)}",
                          Layout.poll_div(QUEUE_CONTENT_ID, request.script_name, "queues/#{name}", content),
                          script_name: request.script_name)
            end
          end

          # `raw` is the exact JSON string the job entry was pushed with —
          # same "raw" identity `Routes::Dead`/`Routes::Retries` already key
          # their own per-row delete off — so `Queue#delete` can `LREM` it
          # back out of the list.
          app.post('/queues/:name/delete') do
            name = url_params('name')
            Cogworker::Queue.new(name).delete(params['raw'])
            Queues.respond(self, name)
          end

          app.post('/queues/:name/delete_all') do
            name = url_params('name')
            Cogworker::Queue.new(name).clear
            Queues.respond(self, name)
          end
        end

        # After an action, htmx gets the refreshed fragment swapped into
        # #queue-content in place; a plain form submission (no JS) falls
        # back to a normal redirect back to the queue's own page.
        def respond(action, name)
          if action.hx_request?
            render_queue_content(name, action.request.script_name)
          else
            action.redirect(Layout.path(action.request.script_name, "queues/#{name}"))
          end
        end

        def render_content(script_name)
          names = Cogworker.config.redis { |c| c.smembers(RedisKeys::QUEUES) }.sort
          rows = names.map do |name|
            q = Cogworker::Queue.new(name)
            link = Layout.path(script_name, "queues/#{Layout.h(name)}")
            [%(<a class="text-indigo-600 dark:text-indigo-400 hover:underline font-medium" href="#{link}">#{Layout.h(name)}</a>),
             q.size, q.latency.round(2)]
          end
          Layout.table(%w[Name Size Latency], rows, empty_message: 'No queues yet — push a job to create one.')
        end

        def render_queue_content(name, script_name)
          delete_path = Layout.path(script_name, "queues/#{name}/delete")
          rows = Cogworker::Queue.new(name).map do |r|
            [r.jid, Layout.h(r.klass), Layout.h(r.args.to_s),
             Layout.form_button(delete_path, 'raw', r.value, 'delete', hx_target: "##{QUEUE_CONTENT_ID}",
                                                                       variant: :danger)]
          end
          delete_all_button(name, script_name, rows.empty?) +
            Layout.table(%w[JID Class Args Delete], rows, empty_message: 'This queue is empty.')
        end

        # Nothing to bulk-delete once the queue is already empty.
        def delete_all_button(name, script_name, empty)
          return '' if empty

          delete_all_path = Layout.path(script_name, "queues/#{name}/delete_all")
          button = Layout.action_button(delete_all_path, 'delete all', hx_target: "##{QUEUE_CONTENT_ID}",
                                                                       variant: :danger)
          %(<div class="mb-3 flex justify-end">#{button}</div>)
        end
      end
    end
  end
end

Cogworker::Web.register(Cogworker::Web::Routes::Queues)
