# frozen_string_literal: true

# Example Web UI mount. Run with:
#
#   COGWORKER_EXAMPLE_REDIS_URL=redis://localhost:6379/0 bundle exec rackup ./examples/config.ru -p 9394
#
# then open http://localhost:9394/cogworker

require_relative 'init'

# Reference the constants directly rather than `require`-ing their file
# paths: Cogworker uses Zeitwerk for autoloading (and, when
# COGWORKER_RELOAD=true, reloading) — a raw `require 'cogworker/web'` loads
# the file fine, but bypasses Zeitwerk's own tracking of what it loaded, so
# a later `Cogworker::LOADER.reload` can leave it in an inconsistent state.
Cogworker::Web
# GET /metrics (Cogworker::Prometheus::Exporter) is mounted automatically by
# Cogworker::Web.load_routes! — nothing to reference here. Opt out with
# Cogworker::Web.prometheus_exporter_enabled = false if you don't want it.

# Every timestamp in the Web UI (Busy/Scheduled/Dead) renders in the
# *browser's* local timezone, formatted with this Time#strftime pattern —
# the same tokens are reused client-side, just against local instead of UTC.
Cogworker::Web.time_format = '%d.%m.%Y %H:%M:%S'

# How often (seconds) every auto-refreshing tab polls while the global
# "Live" toggle in the header is on — shared by the htmx-polled Busy/Stats/
# Queues tabs and History's own AG Grid refresh.
Cogworker::Web.live_update_interval = 5

# A toy stand-in for a real SSO auth middleware, showing `Web.use` wrapping
# the whole app *inside* Cogworker::Web's own Rack stack (session cookie,
# then this). A real implementation would check a real session/token here.
class DemoAuthMiddleware
  def initialize(app)
    @app = app
  end

  def call(env)
    @app.call(env)
  end
end
Cogworker::Web.use(DemoAuthMiddleware)

map '/cogworker' do
  run Cogworker::Web
end

map '/' do
  run ->(_env) { [302, { 'location' => '/cogworker' }, []] }
end
