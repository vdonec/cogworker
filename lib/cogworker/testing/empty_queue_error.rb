# frozen_string_literal: true

module Cogworker
  module Testing
    # Raised by `Testing.perform_one`/`SomeJob.perform_one` when fake mode
    # has nothing recorded for that class.
    class EmptyQueueError < StandardError; end
  end
end
