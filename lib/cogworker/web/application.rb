# frozen_string_literal: true

module Cogworker
  class Web
    # The shared route table. Built-in tabs register through the exact same
    # `self.get`/`register` mechanism external extensions use (dogfooding),
    # so there's only one code path to keep working.
    module Application
      class << self
        def routes
          @routes ||= []
        end

        def get(path, &block)
          add_route('GET', path, &block)
        end

        def post(path, &block)
          add_route('POST', path, &block)
        end

        # `mod.registered(self)` — `self` here is this Application module,
        # so inside `registered` the extension calls `app.get(...)` against
        # it directly, matching TZ's Sinatra-style `self.registered(app)`.
        def register(mod)
          mod.registered(self)
        end

        def call(env)
          request = Rack::Request.new(env)
          # Rack::URLMap sets PATH_INFO to "" (not "/") for a request that
          # exactly matches a mount point with no trailing slash — normalize
          # it so the root route still matches when this app is `map`'d.
          path_info = request.path_info.empty? ? '/' : request.path_info
          route = routes.reverse.find do |r|
            r[:method] == request.request_method && Router.match(r[:pattern], path_info)
          end
          return not_found unless route

          captures = Router.match(route[:pattern], path_info)
          action = Action.new(request, captures)
          result = catch(:halt) { action.instance_exec(&route[:block]) }
          rack_triple?(result) ? result : [200, { 'content-type' => 'text/html; charset=utf-8' }, [result.to_s]]
        end

        private

        def add_route(method, path, &block)
          routes << { method: method, pattern: Router.compile(path), block: block }
        end

        def rack_triple?(value)
          value.is_a?(Array) && value.size == 3 && value.first.is_a?(Integer)
        end

        def not_found
          [404, { 'content-type' => 'text/plain' }, ['Not Found']]
        end
      end
    end
  end
end
