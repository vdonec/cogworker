# frozen_string_literal: true

require 'erb'

module Cogworker
  class Web
    # A fresh instance per request (never reused across requests/threads, so
    # there's no cross-thread state to worry about). A registered route
    # block is `instance_exec`'d against one of these, giving it bare
    # `request`/`params`/`erb`/`redirect` the way TZ describes.
    class Action
      attr_reader :request, :params

      def initialize(request, path_params)
        @request = request
        @params = request.params.merge(path_params)
      end

      # An extension's own routes may read either style — `params['x']` or
      # `url_params('x')` (the latter is what the real History tab uses).
      def url_params(key)
        params[key.to_s]
      end

      # htmx sends this header on every request it issues (both its
      # polling `hx-trigger` fetches and its `hx-post` form submissions), so
      # a route can tell "the page is asking for a fragment to swap in"
      # apart from a plain browser navigation — and fall back to a normal
      # full-page render (or redirect) for anyone/anything without JS.
      def hx_request?
        request.get_header('HTTP_HX_REQUEST') == 'true'
      end

      # Accepts a Symbol (a built-in template, looked up in web/views/) or a
      # raw ERB-source String (an extension handing over `File.read(...)`
      # itself, as the real History tab does).
      def erb(template, locals: {})
        source = template.is_a?(Symbol) ? Views.read(template) : template
        locals_binding = build_binding(locals)
        ERB.new(source).result(locals_binding)
      end

      def redirect(location)
        # Header names must be lowercase per the Rack spec — Rack::Lint
        # (which Puma's default dev environment runs requests through)
        # raises on a capitalized 'Location'.
        halt([302, { 'location' => location }, []])
      end

      def halt(response)
        throw :halt, response
      end

      private

      def build_binding(locals)
        b = binding
        locals.each { |k, v| b.local_variable_set(k, v) }
        b
      end
    end
  end
end
