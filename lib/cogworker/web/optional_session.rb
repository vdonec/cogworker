# frozen_string_literal: true

require 'rack/session/cookie'

module Cogworker
  class Web
    # The Web UI's own session cookie, applied only when nothing upstream
    # already provides `env['rack.session']`. Mounted inside an app that has
    # its own session (Rails, or any `Rack::Session::*` in front), an
    # unconditional `Rack::Session::Cookie` here replaced that session with
    # a copy for everything inside the Web UI — so an auth middleware added
    # via `Web.use` read and wrote the copy, never the host's real session,
    # and every response carried a second `cogworker.session` cookie.
    class OptionalSession
      def initialize(app, **options)
        @app = app
        @with_session = Rack::Session::Cookie.new(app, **options)
      end

      def call(env)
        env['rack.session'] ? @app.call(env) : @with_session.call(env)
      end

      # A session middleware added via `Web.use` sits *after* this one in
      # the stack, so it can't be detected per request the way an upstream
      # one is — `Web.build_app` checks for one up front instead.
      def self.session_middleware?(middleware)
        middleware.is_a?(Class) && middleware <= Rack::Session::Abstract::Persisted
      end
    end
  end
end
