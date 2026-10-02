# frozen_string_literal: true

module Cogworker
  class ReliableFetch
    # Raised by ReliableFetch#retrieve_work when the server turns out not to
    # know LMOVE (Redis < 6.2) even though the version check at boot let
    # `:reliable` through (e.g. Redis wasn't reachable then). The Processor
    # reacts by switching the whole Manager over to BasicFetch.
    class UnsupportedError < StandardError; end
  end
end
