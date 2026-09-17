# frozen_string_literal: true

# A plain job: `include Cogworker::Worker`, a `perform` method, no options.
class GreetingJob
  include Cogworker::Worker

  def perform(name)
    Cogworker.logger.info { "Hello, #{name}!" }
  end
end
