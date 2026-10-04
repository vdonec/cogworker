# frozen_string_literal: true

module Cogworker
  module History
    # Server middleware: times every run and records it via Storage,
    # success or failure, regardless of what other middleware/worker code does.
    class Middleware
      # Recording is best-effort (BestEffort): only the job's own exception
      # is re-raised, never one from writing its history.
      def call(_worker, job, queue)
        started_at = Time.now.to_f
        begin
          yield
        rescue Exception => e # rubocop:disable Lint/RescueException
          BestEffort.call('History') { Storage.record(job, queue, started_at, Time.now.to_f, 'failed', error: e) }
          raise e
        end
        BestEffort.call('History') { Storage.record(job, queue, started_at, Time.now.to_f, 'success') }
      end
    end
  end
end
