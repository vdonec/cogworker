# frozen_string_literal: true

module Cogworker
  # Execution history: every job run (success and failure alike) is recorded
  # with its full args, timing, and — on failure — error class/message/
  # backtrace. Distinct from the Status layer (`Cogworker::Status`), which
  # tracks *current* per-jid state with a TTL; History is an append-only,
  # length-capped log meant for browsing/auditing past runs.
  module History
    DEFAULT_MAX_ENTRIES = 1000

    class << self
      # How many entries are retained (oldest trimmed first), independently
      # for the "all", "success", and "failed" lists — read fresh on every
      # write, so changing it takes effect immediately, no need to rebuild
      # the middleware chain. Configurable via
      # `configure_server_middleware(config, max_entries: N)`, or directly:
      # `Cogworker::History.max_entries = 5000`.
      attr_writer :max_entries

      def max_entries
        @max_entries ||= DEFAULT_MAX_ENTRIES
      end
    end

    module_function

    def configure_server_middleware(config, max_entries: DEFAULT_MAX_ENTRIES)
      self.max_entries = max_entries
      config.server_middleware { |chain| chain.add(Middleware) }
    end
  end
end
