# frozen_string_literal: true

module Cogworker
  module History
    # Server middleware: times every run and records it via Storage,
    # success or failure, regardless of what other middleware/worker code does.
    class Middleware
      def call(_worker, job, queue)
        started_at = Time.now.to_f
        yield
        Storage.record(job, queue, started_at, Time.now.to_f, 'success')
      rescue Exception => e # rubocop:disable Lint/RescueException
        Storage.record(job, queue, started_at, Time.now.to_f, 'failed', error: e)
        raise e
      end
    end
  end
end
