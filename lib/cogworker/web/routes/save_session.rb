# frozen_string_literal: true

module Cogworker
  class Web
    module Routes
      # Reserves POST /save_session as a real, always-present route — in
      # practice an external auth middleware wrapping this app (via `Web.use`)
      # typically intercepts this exact path itself before it ever reaches
      # here (that's the whole point of it being a stable, bare, un-prefixed
      # path an auth callback can bypass same-origin checks for). This is
      # just a harmless default for when nothing else claims the path.
      module SaveSession
        def self.registered(app)
          app.post('/save_session') { [200, { 'content-type' => 'text/plain' }, ['OK']] }
        end
      end
    end
  end
end

Cogworker::Web.register(Cogworker::Web::Routes::SaveSession)
