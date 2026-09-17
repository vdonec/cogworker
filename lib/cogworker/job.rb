# frozen_string_literal: true

module Cogworker
  # `include Cogworker::Worker` (alias `Cogworker::Job`) DSL.
  module Job
    def self.included(base)
      base.include(Component)
      base.extend(ClassMethods)
      base.include(InstanceMethods)
    end

    # `cogworker_options`/`perform_async`/`perform_in`/`perform_at`, extended
    # onto the including class.
    module ClassMethods
      # Accepts a plain Hash (both `key: value` and `:key => value` call-site
      # syntax already collect into the same Hash literal in Ruby — nothing
      # special to implement). Merges into the class's option set rather than
      # replacing it, and never filters keys: arbitrary custom options (e.g.
      # `lock_run: :while_executing`) ride along unchanged into the job hash.
      def cogworker_options(opts = {})
        cogworker_options_hash.merge!(opts.transform_keys(&:to_sym))
        cogworker_options_hash
      end

      def cogworker_options_hash
        @cogworker_options_hash ||= if superclass.respond_to?(:cogworker_options_hash)
                                      superclass.cogworker_options_hash.dup
                                    else
                                      {}
                                    end
      end

      def perform_async(*args)
        Client.push(job_payload('args' => args))
      end

      def perform_in(interval, *args)
        ts = interval_to_ts(interval)
        Client.push(job_payload('args' => args, 'at' => ts))
      end
      alias perform_at perform_in

      # `SomeJob.jobs`/`SomeJob.clear` — reads/clears this class's entries in
      # `Cogworker::Testing`'s fake queue (empty outside `Testing.fake!`).
      def jobs
        Testing.jobs_for(name)
      end

      def clear
        Testing.jobs_for(name).clear
      end

      private

      def job_payload(extra)
        cogworker_options_hash.transform_keys(&:to_s).merge('class' => name).merge(extra)
      end

      def interval_to_ts(interval)
        numeric = interval.respond_to?(:to_f) ? interval.to_f : interval.to_time.to_f
        # A value below a billion is treated as "seconds from now"
        # (perform_in), anything
        # at or above it as an absolute unix timestamp (perform_at, or a
        # Time passed straight through — Time#to_f is already an epoch
        # timestamp, always well above the threshold).
        numeric < 1_000_000_000 ? Time.now.to_f + numeric : numeric
      end
    end

    # `jid`, included onto the including class's instances.
    module InstanceMethods
      attr_accessor :jid
    end
  end
end
