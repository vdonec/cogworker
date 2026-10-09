# frozen_string_literal: true

module Cogworker
  # Handed to death hooks (DeathNotifier) for a job buried because its
  # process kept dying while running it — there's no exception of its own.
  class JobOrphanedError < StandardError
  end
end
