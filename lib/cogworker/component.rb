# frozen_string_literal: true

module Cogworker
  # Mixin giving any class `#identity`/`#logger`, delegating to the
  # process-global `Cogworker.identity`/`Cogworker.logger`. Deliberately global
  # (not instance-scoped config injection): each OS process — including every
  # cogworkerswarm child — has exactly one Cogworker::Config, so a singleton-backed
  # mixin is sufficient and keeps `include Cogworker::Component` usable with zero
  # wiring, as existing custom middleware (e.g. WorkerKiller) expects.
  module Component
    def identity
      Cogworker.identity
    end

    def logger
      Cogworker.logger
    end
  end
end
