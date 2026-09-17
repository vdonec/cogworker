# frozen_string_literal: true

require 'json'

module Cogworker
  # Wraps one job hash pulled off a queue/zset with the delegates TZ 3.4
  # requires. `#klass` (not `#class`) deliberately — overriding Object#class
  # would break is_a?/respond_to?, and the one real caller in this codebase
  # only ever reads `.item['class']` off the hash directly, never a method
  # on this wrapper.
  class JobRecord
    attr_reader :item, :value

    def initialize(value)
      @value = value
      @item = JSON.parse(value)
    end

    def klass = item['class']
    def args = item['args']
    def queue = item['queue']
    def jid = item['jid']
  end
end
