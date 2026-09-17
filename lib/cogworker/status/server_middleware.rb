# frozen_string_literal: true

module Cogworker
  module Status
    # Server middleware: writes 'working' before perform, then
    # 'complete'/'failed'/'retrying' after, per `JobUtil.terminal_failure?`.
    class ServerMiddleware
      def initialize(expiration)
        @expiration = expiration
      end

      def call(_worker, job, queue)
        write(job, queue, 'working')
        yield
        write(job, queue, 'complete')
      rescue Exception => e # rubocop:disable Lint/RescueException
        write(job, queue, JobUtil.terminal_failure?(job) ? 'failed' : 'retrying',
              error_class: e.class.name, error_message: e.message.to_s[0, 10_000])
        raise e
      end

      private

      def write(job, queue, status, error_class: nil, error_message: nil)
        Storage.write(job['jid'], @expiration, 'status' => status, 'update_time' => Time.now.to_f,
                                               'class' => job['class'], 'queue' => queue,
                                               'error_class' => error_class, 'error_message' => error_message)
      end
    end
  end
end
