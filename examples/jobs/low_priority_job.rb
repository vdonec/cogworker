# frozen_string_literal: true

# Demonstrates pinning a job to a non-default queue via `cogworker_options
# queue:` — `examples/cogworker.yml` already lists `low` (alongside `default`
# listed twice, for weight) as one of the queues a worker polls; nothing
# used to actually enqueue onto it, so it always sat empty in the Web UI.
class LowPriorityJob
  include Cogworker::Worker

  cogworker_options queue: 'low'

  def perform(name)
    Cogworker.logger.info { "Low-priority: #{name}" }
  end
end
