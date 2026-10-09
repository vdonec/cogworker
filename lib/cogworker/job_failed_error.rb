# frozen_string_literal: true

module Cogworker
  # Handed to death hooks (DeathNotifier) for a failure filed in dead later,
  # from its stored record, when the original exception object is long gone.
  # The message is the original one; its class is in `job['error_class']`.
  class JobFailedError < StandardError
  end
end
