# frozen_string_literal: true

require 'rack'
require 'rack/session/cookie'
require 'rack/static'
require 'securerandom'

module Cogworker
  # Rack entry point: `map('/mount-point') { run Cogworker::Web }`.
  #
  # A plain, reopenable class on purpose — `safe_request?` is meant to be
  # overridden by whoever mounts this (e.g. to let one specific external
  # callback path through a same-origin check) without needing any hook
  # mechanism from this gem: `class Cogworker::Web; def self.safe_request?(env);
  # ...; end; end` just works, the same way monkey-patching any Ruby class
  # does. Note the `self.` — `safe_request?` is defined inside `class << self`
  # below (it's called as `Cogworker::Web.safe_request?`, not on an
  # instance), so reopening it as a plain instance method is a silent no-op.
  class Web
    # Every built-in tab lives under here; touching each constant once
    # forces Zeitwerk to load that file (and run its
    # `Cogworker::Web.register(...)` bottom-of-file side effect) — nothing
    # else ever references `Routes::Queues` etc. by name, so without this
    # they would simply never load.
    BUILT_IN_ROUTE_NAMES = %i[Queues Busy Retries Scheduled Periodic Dead History Stats SaveSession].freeze
    DEFAULT_TIME_FORMAT = '%Y-%m-%d %H:%M:%S'
    DEFAULT_HISTORY_PER_PAGE = 25
    DEFAULT_LIVE_UPDATE_INTERVAL = 3

    # htmx/Tailwind/AG Grid are vendored under here (not fetched from a CDN)
    # so the Web UI works with no internet access at all — see `Layout`'s
    # `<script>`/`<link>` tags and `Routes::History#ag_grid_head`, all of
    # which build their `src`/`href` as `path(script_name, 'assets/...')`,
    # same as every other in-app link. `root:` is this directory's *parent*
    # (not `assets/` itself) because `Rack::Static` appends the full,
    # unstripped request path (e.g. `/assets/htmx.min.js`) onto `root`.
    ASSETS_ROOT = File.join(__dir__, 'web')

    # Guards every request's dispatch while reloading is enabled — a plain
    # class-level constant (not lazily memoized via `||=`, which would
    # itself race) so it exists before any request can possibly reach it.
    # See `call`/`dispatch` below for why this has to wrap the *entire*
    # request, not just `reload!`.
    RELOAD_MUTEX = Mutex.new

    class << self
      # While `COGWORKER_RELOAD=true`, the whole request — the reload
      # itself *and* the route handling that follows — runs inside
      # `RELOAD_MUTEX`, not just the `Cogworker::LOADER.reload` call.
      # `Zeitwerk::Loader#reload`'s `unload` step removes every constant it
      # manages *process-wide* for the duration of the reload, not just
      # from this thread's point of view — so a second thread mid-`app.call`
      # (already past its own `reload!`, now executing a route that
      # references `Layout`/`WorkSet`/etc.) can have those constants yanked
      # out from under it and raise `NameError`, even though it never
      # touched `reload!` concurrently itself. Only wrapping `reload!` (an
      # earlier version of this fix) stopped the *permanent* `Zeitwerk::
      # SetupRequired` wedge but not this — both were caught by
      # `spec/cogworker/web_reload_spec.rb`'s concurrent-requests spec,
      # which spawns several threads hammering `.call` at once. Outside
      # `COGWORKER_RELOAD` (i.e. every real worker-adjacent Web process)
      # `reloading?` is false and this adds no locking at all.
      def call(env)
        if reloading?
          RELOAD_MUTEX.synchronize do
            reload!
            dispatch(env)
          end
        else
          dispatch(env)
        end
      end

      # Extends the Rack middleware stack this Web app itself runs behind
      # (session cookie, an auth middleware wrapping the whole app) —
      # distinct from mounting external middleware *outside* this app via
      # plain `Rack::Builder`/`map`, which also works and needs nothing from
      # here.
      def use(middleware, *args)
        middlewares << [middleware, args]
        @app = nil
      end

      def register(extension, name: extension.to_s, tab: nil, index: nil)
        Cogworker::Web::Application.register(extension)
        tabs[tab] = index if tab && index
        name
      end

      # Public, mutable: `Cogworker::Web.tabs['History'] = 'history'` is how
      # a registered extension actually gets a nav entry.
      def tabs
        @tabs ||= {}
      end

      def session_secret
        @session_secret ||= SecureRandom.hex(32)
      end

      # How every `Layout.time_tag` timestamp is rendered — a Ruby
      # `Time#strftime` pattern, reused as-is client-side (the same tokens:
      # %Y %m %d %H %M %S %B %b %A %a %p), just evaluated against the
      # browser's local time instead of the server's UTC fallback. Set this
      # from your own init file/config.ru, e.g.
      # `Cogworker::Web.time_format = '%d.%m.%Y %H:%M'`.
      def time_format
        @time_format ||= DEFAULT_TIME_FORMAT
      end

      attr_writer :time_format, :history_per_page, :live_update_interval, :prometheus_exporter_enabled

      # Whether `GET /metrics` (`Cogworker::Prometheus::Exporter`, mounted
      # automatically by `load_routes!` below like any other built-in) is
      # actually served — checked at request time by the exporter's own
      # route, not here, so this can be set any time before a request comes
      # in, same as `time_format`/`live_update_interval`. Set this to
      # `false` from your own init file/config.ru to opt back out, e.g. if
      # you'd rather scrape metrics through a separate, unauthenticated
      # mount and don't want `/metrics` reachable behind this one at all.
      def prometheus_exporter_enabled
        return true unless defined?(@prometheus_exporter_enabled)

        @prometheus_exporter_enabled
      end

      # Rows per page on the History tab. Retention depth (how many entries
      # exist to page through at all) is a separate, gem-wide setting:
      # `Cogworker::History.max_entries`.
      def history_per_page
        @history_per_page ||= DEFAULT_HISTORY_PER_PAGE
      end

      # How often (in seconds) every auto-refreshing tab polls while the
      # global live-update toggle is on — both the htmx-polled Busy/Stats/
      # Queues tabs (`Layout.poll_div`'s `hx-trigger="every Ns [...]"`) and
      # History's own AG Grid `refreshRows()` JS poll share this one value,
      # so there's a single knob rather than one per tab. Set this from your
      # own init file/config.ru, e.g. `Cogworker::Web.live_update_interval = 10`.
      def live_update_interval
        @live_update_interval ||= DEFAULT_LIVE_UPDATE_INTERVAL
      end

      # A minimal same-origin check (default-open for safe/read-only HTTP
      # methods, otherwise requires `Sec-Fetch-Site: same-origin`).
      # Reopen this method to carve out an exception for a specific
      # cross-site callback path (e.g. an SSO provider's POST redirect).
      def safe_request?(env)
        return true if safe_method?(env['REQUEST_METHOD'])

        env['HTTP_SEC_FETCH_SITE'] == 'same-origin'
      end

      def safe_method?(method)
        %w[GET HEAD OPTIONS].include?(method)
      end

      def reloading?
        Cogworker::LOADER.reloading_enabled?
      end

      # Only ever called from `.call` above (always already holding
      # `RELOAD_MUTEX` — see there for why), i.e. only while handling a Web
      # UI HTTP request — never from a job-processing thread. Note this
      # reloads Zeitwerk's *entire* managed tree (there's one loader for the
      # whole gem), not just lib/cogworker/web/**: editing an engine file
      # (Processor, Config, ...) while a dev Web UI process is up will also
      # pick up those changes on the next request. That's harmless for a
      # process that only ever serves HTTP and never runs `Launcher`, but is
      # exactly why this must never be wired into `exe/cogworker`.
      #
      # `Cogworker::Web` itself is *not* meaningfully reloadable: Rack
      # captures a single reference to this class object once, at `run
      # Cogworker::Web` boot time, and calls that same object's `.call`
      # forever — editing this file's own methods (`call`, `build_app`, ...)
      # has no effect without a real process restart. What *does* refresh
      # every request is everything this class only ever reaches through a
      # fresh, fully-qualified lookup: `@app` is rebuilt every time (so it
      # re-resolves `Cogworker::Web::Application`, not a memoized stale
      # reference to whatever object used to be there), and that in turn
      # re-executes `Routes::*`/`Layout`/`Router`/`Action` fresh, so their
      # bare cross-references to each other stay internally consistent.
      def reload!
        @tabs = {}
        @app = nil
        Cogworker::LOADER.reload
        load_routes!
      end

      # Fully-qualified references throughout, not bare `Application`/
      # `Routes`: right after `Zeitwerk::Loader#reload`, a bare constant
      # lookup relying on lexical nesting can fail to find a freshly
      # re-armed autoload even though the constant is genuinely there —
      # `Cogworker::Web::Routes` resolves correctly where a bare `Routes`
      # (searched via Module.nesting from inside this method) sometimes
      # raises `NameError` immediately after a reload. Fully-qualifying
      # sidesteps it entirely.
      def load_routes!
        BUILT_IN_ROUTE_NAMES.each { |name| Cogworker::Web::Routes.const_get(name) }
        # Different namespace (Cogworker::Prometheus::Exporter, not
        # Cogworker::Web::Routes::*) so it can't join BUILT_IN_ROUTE_NAMES
        # above, but touching the constant is the same Zeitwerk-autoload
        # trick either way: it runs that file's own bottom-of-file
        # `Cogworker::Web.register(...)` exactly like a route file would.
        # Previously this constant was only ever touched by an app's own
        # init code remembering to reference it — forgetting to do so left
        # `/metrics` returning a plain 404 with no indication why the route
        # was missing.
        # Mounting it always and gating on `prometheus_exporter_enabled`
        # instead (checked inside the route itself, not here) fixes that
        # while keeping the opt-out.
        Cogworker::Prometheus::Exporter
      end

      private

      def dispatch(env)
        return forbidden(env) unless safe_request?(env)

        app.call(env)
      end

      def forbidden(_env)
        [403, { 'content-type' => 'text/plain' }, ['Forbidden']]
      end

      def middlewares
        @middlewares ||= []
      end

      def app
        @app ||= build_app
      end

      def build_app
        builder = Rack::Builder.new
        builder.use(Rack::Session::Cookie, secret: session_secret, key: 'cogworker.session')
        # No `cache_control:` (no `immutable`/long `max-age`): these files
        # are plain, unfingerprinted paths that *do* change — every time
        # this gem's Tailwind bundle gets rebuilt, or on any gem upgrade —
        # and `immutable` previously told browsers to keep serving a stale
        # cached copy under the old URL for up to a year with no
        # revalidation at all (caught by hand: a real edit to tailwind.css
        # didn't show up in an already-open tab until a hard reload).
        # `Rack::Static`/`Rack::Files` already sends `Last-Modified` and
        # honors conditional GETs by default, which is all that's needed
        # here — a browser still avoids a full re-download when nothing
        # changed, but always gets fresh content the moment something did.
        builder.use(Rack::Static, urls: ['/assets'], root: ASSETS_ROOT)
        middlewares.each { |mw, args| builder.use(mw, *args) }
        builder.run(Cogworker::Web::Application)
        builder.to_app
      end
    end
  end
end

Cogworker::Web.load_routes!
