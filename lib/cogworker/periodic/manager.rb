# frozen_string_literal: true

module Cogworker
  module Periodic
    # DSL object yielded to `config.periodic { |mgr| mgr.register(...) }`.
    # Collects entries synchronously as the block runs; the actual cron
    # ticking/claiming (Periodic::Ticker) starts later, from each process's
    # post-fork startup hook, and reads the entries accumulated here.
    class Manager
      attr_reader :entries

      def initialize
        @entries = []
      end

      # `retry:` can't be read back as a bare local variable inside the
      # method body (Ruby always lexes a bare `retry` as the retry-keyword,
      # even when it's also a keyword-arg name), so options are captured via
      # **opts instead of named keyword params.
      def register(cron, class_name, **opts)
        entry = Entry.new(cron: cron, class_name: class_name, retry: opts[:retry] || 0,
                          unique: opts[:unique], args: opts[:args] || [])
        @entries << entry
        entry
      end
    end
  end
end
