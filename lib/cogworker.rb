# frozen_string_literal: true

require 'socket'
require 'securerandom'
require 'zeitwerk'

# Redis-backed background job processing: worker DSL, periodic (cron)
# scheduling, process introspection, a Web UI, and a Prometheus exporter.
module Cogworker
  # `LOADER` autoloads everything under lib/cogworker/** — no internal
  # `require_relative` between this gem's own files anywhere below; just
  # reference the constant, Zeitwerk resolves file <-> constant by
  # directory structure (lib/cogworker/foo/bar.rb <-> Cogworker::Foo::Bar).
  # Two inflections don't follow the default snake_case -> CamelCase rule:
  # `version.rb` defines the constant `VERSION` (conventional for gems, not
  # `Version`), and `cli.rb` defines `CLI` (an acronym, not `Cli`).
  LOADER = Zeitwerk::Loader.for_gem
  LOADER.inflector.inflect('version' => 'VERSION', 'cli' => 'CLI')

  # Reloading is opt-in and, by design, only ever triggered from
  # `Cogworker::Web.call` (see web.rb) — never from a job-processing
  # Processor thread. Redefining a job class's constant while another
  # thread is mid-`perform` on an instance of it is exactly the kind of
  # hazard Rails-style reloading is unsafe for in a worker process, which
  # is why this must be enabled (if at all) only for a Web UI process, via
  # `COGWORKER_RELOAD=true` — never unconditionally, never in `exe/cogworker`
  # or `exe/cogworkerswarm`'s own boot path.
  LOADER.enable_reloading if ENV['COGWORKER_RELOAD'] == 'true'
  LOADER.setup

  class << self
    def logger
      @logger ||= Logging.default_logger
    end

    attr_writer :logger

    def config
      @config ||= Config.new
    end

    # Skipping the block when `server?` is false is by design for a plain
    # Web-only process (see `server?` below) — not necessarily a mistake, so
    # this only logs at `debug` (silent under the default `info` level; bump
    # `Cogworker.logger.level = Logger::DEBUG` while integrating to see it).
    # It's the same skip either way whether that's intentional or the app's
    # init file just happened to load before the CLI/swarm boot path called
    # `server_process!` — this gem can't tell those apart, so it can only
    # ever hint, not warn outright.
    def configure_server
      if server?
        yield config
      else
        logger.debug do
          'Cogworker.configure_server skipped: Cogworker.server? is false right now — either ' \
            'intentional (a Web-only process), or configure_server ran before ' \
            'Cogworker.server_process! was set (check init/boot ordering).'
        end
      end
    end

    def configure_client
      if server?
        logger.debug do
          'Cogworker.configure_client skipped: Cogworker.server? is true right now — either ' \
            'intentional (a worker-only process with no client-side pushes), or configure_client ' \
            'ran after Cogworker.server_process! was already set (check init/boot ordering).'
        end
      else
        yield config
      end
    end

    # Whether this process is a Cogworker worker process (set by the CLI/swarm
    # boot sequence before requiring app code). A plain web process loading
    # the same initializer file should skip `configure_server` blocks (no
    # Redis pool / middleware chain needed there) — this flag is what makes
    # that possible without changing the initializer.
    def server?
      !!@server_process
    end

    def server_process!
      @server_process = true
    end

    # No-op: exists so calling code doesn't need to change, but this gem
    # simply never coerces job args, so there is nothing to toggle.
    def strict_args!(_value = true)
      true
    end

    # Recomputed fresh in every cogworkerswarm child (see Cogworker::Swarm) —
    # never memoize this before a fork, or every child collapses onto the
    # parent's identity in the heartbeat/ProcessSet/WorkSet Redis keys.
    def identity
      @identity ||= compute_identity
    end

    def reset_identity!
      @identity = compute_identity
    end

    def hostname
      ENV['DYNO'] || Socket.gethostname
    end

    private

    def compute_identity
      "#{hostname}:#{::Process.pid}:#{SecureRandom.hex(6)}"
    end
  end
end
