# frozen_string_literal: true

module Cogworker
  module Middleware
    # One registered middleware: a class plus the args its initializer takes.
    # A fresh instance is built on every #invoke (not cached/reused) — some
    # existing middleware (e.g. a WorkerKiller with a class-level Mutex
    # constant) is written expecting per-call instantiation.
    Entry = Struct.new(:klass, :args) do
      def build
        klass.new(*args)
      end
    end

    # An ordered list of middleware. #add appends, preserving registration
    # order as call order. Works for both the server chain
    # (call(worker, job, queue, &block)) and the client chain
    # (call(worker_class, job, queue, redis_pool, &block)) — the chain itself
    # is arity-agnostic, it just threads whatever args #invoke is given
    # through every entry plus a continuation block.
    class Chain
      include Enumerable

      def initialize
        @entries = []
      end

      def add(klass, *args)
        remove(klass)
        @entries << Entry.new(klass, args)
        self
      end

      def remove(klass)
        @entries.delete_if { |e| e.klass == klass }
      end

      def each(&block)
        @entries.each(&block)
      end

      def empty?
        @entries.empty?
      end

      # Invokes every entry in registration order, each wrapping the next,
      # with `final_block` as the innermost call.
      def invoke(*call_args, &final_block)
        traverse(@entries.dup, call_args, &final_block)
      end

      private

      def traverse(remaining, call_args, &final_block)
        if remaining.empty?
          final_block.call
        else
          entry = remaining.shift
          entry.build.call(*call_args) { traverse(remaining, call_args, &final_block) }
        end
      end
    end
  end
end
