# frozen_string_literal: true

module Cogworker
  # One in-flight job on one process/thread.
  class Work
    attr_reader :process_id, :thread_id

    def initialize(process_id, thread_id, hash)
      @process_id = process_id
      @thread_id = thread_id
      @hash = hash
    end

    def queue = @hash['queue']
    def run_at = @hash['run_at']
    # already a Hash: nested by the outer JSON.parse in WorkSet#each
    def job = @hash['payload']
  end
end
