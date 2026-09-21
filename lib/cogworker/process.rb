# frozen_string_literal: true

module Cogworker
  # One live worker process, looked up by heartbeat key. `#quiet!`/`#resume!`/
  # `#stop!` publish to that process's signal channel; the process (whether
  # that's this same process — e.g. WorkerKiller finding itself via
  # ProcessSet — or a genuinely remote one) is subscribed to it and reacts.
  # `#quiet!`/`#stop!` mirror a real `kill -TSTP`/`TERM`; `#resume!` has no
  # OS-signal equivalent (there's no `SIGCONT`-style un-quiet in real
  # Sidekiq-alike tooling) — it's Cogworker-specific, made possible by
  # `Manager#quiet` being a plain in-memory flag rather than a one-way state
  # transition like `stopping?`.
  #
  # Named `Cogworker::Process`, not `::Process` — inside this namespace a
  # bare `Process` resolves to this class, not the Kernel module, so any
  # code in lib/cogworker/** that means the OS process must say `::Process`
  # explicitly.
  class Process
    def initialize(hash)
      @hash = hash
    end

    def [](key) = @hash[key]
    def identity = @hash['identity']

    def quiet!
      publish('quiet')
    end

    def resume!
      publish('resume')
    end

    def stop!
      publish('stop')
    end

    private

    def publish(message)
      Cogworker.config.redis { |c| c.publish(RedisKeys.signal(identity), message) }
    end
  end
end
