# frozen_string_literal: true

module Cogworker
  module Status
    # Server middleware: writes 'working' before perform, then
    # 'complete'/'failed'/'retrying' after, per `JobUtil.terminal_failure?`.
    class ServerMiddleware
      def initialize(expiration)
        @expiration = expiration
      end

      # Every status write is best-effort (BestEffort) — before `perform`
      # as much as after: one failing used to count as the job failing.
      def call(_worker, job, queue)
        BestEffort.call('Status') { write(job, queue, 'working') }
        begin
          yield
        rescue Exception => e # rubocop:disable Lint/RescueException
          BestEffort.call('Status') do
            write(job, queue, JobUtil.terminal_failure?(job) ? 'failed' : 'retrying',
                  error_class: e.class.name, error_message: JobUtil.error_message(e))
          end
          raise e
        end
        BestEffort.call('Status') { write(job, queue, 'complete') }
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
