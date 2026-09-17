# frozen_string_literal: true

module Cogworker
  # Job status/progress tracking: `status:<jid>` in Redis, TTL = the
  # `expiration:` passed to configure_*_middleware. Real usage reads a wider
  # status vocabulary than the base queued/working/complete/failed set —
  # `retrying` (a failed attempt with retries left) is produced here too.
  # `stopped`/`interrupted` are valid values this schema supports (an
  # external reconciler could write them for a job whose owning process
  # vanished mid-flight) but nothing in this gem produces them automatically
  # yet — a crashed process losing its in-flight job's status is the same
  # known limitation as losing the job itself (see Processor/BasicFetch).
  module Status
    DEFAULT_EXPIRATION = 30 * 60 # seconds

    class << self
      attr_accessor :default_expiration
    end

    module_function

    def configure_client_middleware(config, expiration: DEFAULT_EXPIRATION)
      self.default_expiration ||= expiration.to_i
      config.client_middleware { |chain| chain.add(ClientMiddleware, expiration.to_i) }
    end

    def configure_server_middleware(config, expiration: DEFAULT_EXPIRATION)
      self.default_expiration ||= expiration.to_i
      config.server_middleware { |chain| chain.add(ServerMiddleware, expiration.to_i) }
    end

    def status(jid)
      Storage.read(jid)&.fetch('status', nil)
    end

    def get(jid)
      Storage.read(jid)
    end
  end
end
