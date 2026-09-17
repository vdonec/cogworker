# frozen_string_literal: true

module Cogworker
  module Status
    # Client middleware: writes the initial 'queued' status entry right
    # after a job is successfully pushed.
    class ClientMiddleware
      def initialize(expiration)
        @expiration = expiration
      end

      def call(_worker_class, job, queue, _redis_pool = nil)
        yield
        Storage.write(job['jid'], @expiration, 'status' => 'queued', 'update_time' => Time.now.to_f,
                                               'class' => job['class'], 'queue' => queue)
      end
    end
  end
end
