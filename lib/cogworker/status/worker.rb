# frozen_string_literal: true

module Cogworker
  module Status
    # Include-only mixin (`include Cogworker::Status::Worker` alongside
    # `Cogworker::Worker`). Safe to include and never call anything on — the
    # #at/#store helpers below are optional, for a job that wants to report
    # progress mid-perform; nothing about the required queued/working/
    # complete/failed/retrying lifecycle depends on a job ever calling them.
    module Worker
      def at(pct, message = nil)
        Storage.write(jid, expiration, 'status' => 'working', 'update_time' => Time.now.to_f,
                                       'pct' => pct, 'message' => message)
      end

      def store(fields)
        Storage.write(jid, expiration, fields)
      end

      private

      def expiration
        Status.default_expiration || Status::DEFAULT_EXPIRATION
      end
    end
  end
end
