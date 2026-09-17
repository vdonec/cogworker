# frozen_string_literal: true

module Cogworker
  # OS signal names used for process control. `Launcher` (one process) and
  # `Swarm` (the multi-process supervisor) both trap the same quiet/stop
  # pair identically, and `Swarm` relays them on to its children plus its
  # own phased-restart trigger — named here once so the two trap sites and
  # every relay/kill call site can't drift apart.
  module Signals
    QUIET = 'TSTP'
    STOP = 'TERM'
    INTERRUPT = 'INT'
    RESTART = 'USR2'
  end
end
