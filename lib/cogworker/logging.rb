# frozen_string_literal: true

require 'logger'

module Cogworker
  # Builds the default `Logger` (used unless `Cogworker.logger=` overrides
  # it), with a compact one-line-per-entry format including pid.
  module Logging
    def self.default_logger(io = $stdout)
      logger = ::Logger.new(io)
      logger.level = ::Logger::INFO
      logger.formatter = proc do |severity, time, _progname, msg|
        "#{time.utc.iso8601} pid=#{::Process.pid} #{severity}: #{msg}\n"
      end
      logger
    end
  end
end
