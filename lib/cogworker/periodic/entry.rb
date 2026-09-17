# frozen_string_literal: true

require 'digest/sha1'
require 'json'

module Cogworker
  module Periodic
    # One `mgr.register(...)` call. `pjid` is derived purely from the entry's
    # own content (cron + class + args), so it is identical across every
    # process/child that loads the same schedule, and stable across restarts
    # as long as the schedule line itself doesn't change. Two registrations
    # of the same class with different args (seen in the real schedule, e.g.
    # MaterializedViewRefreshTopJob) therefore get distinct, stable pjids.
    Entry = Struct.new(:cron, :class_name, :retry, :unique, :args, keyword_init: true) do
      def pjid
        Digest::SHA1.hexdigest("#{cron}|#{class_name}|#{args.to_json}")
      end

      def until_executed?
        unique == :until_executed
      end
    end
  end
end
