# frozen_string_literal: true

require 'yaml'
require 'erb'

module Cogworker
  # Loads the process config file (`:concurrency:`/`:queues:` YAML, symbol
  # keys, ERB-interpolated before parsing — e.g. `<%= ENV["CONCURRENCY"] %>`).
  # A queue name repeated in `:queues:` is weight, not a duplicate: the
  # repetition survives untouched here and is what BasicFetch's per-cycle
  # shuffle uses to weight fetches.
  module ConfigLoader
    module_function

    def load(path)
      return {} unless path

      erb_result = ERB.new(File.read(path)).result
      YAML.safe_load(erb_result, permitted_classes: [Symbol], aliases: true) || {}
    end
  end
end
