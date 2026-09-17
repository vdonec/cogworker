# frozen_string_literal: true

module Cogworker
  # TZ 3.4 describes Workers and WorkSet with the identical
  # (process_id, thread_id, work) contract, so this is a bare alias, not a
  # second implementation to keep in sync.
  Workers = WorkSet
end
