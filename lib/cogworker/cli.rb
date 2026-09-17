# frozen_string_literal: true

require 'optparse'

module Cogworker
  # Shared flag parsing + boot sequence for both the single-process and
  # swarm-child entry points: `-e/--environment`, `-c/--concurrency`,
  # `-r/--require <file>`, `-C/--config <file>`, `-L/--logfile <file>`,
  # `-q/--queue <name>[,<weight>]` (repeatable).
  class CLI
    def self.parse(argv)
      options = { queues: [], require_path: nil, environment: ENV['APP_ENV'] || ENV['RACK_ENV'] || 'development' }

      OptionParser.new do |o|
        o.on('-e ENV', '--environment ENV') { |v| options[:environment] = v }
        o.on('-c INT', '--concurrency INT', Integer) { |v| options[:concurrency] = v }
        o.on('-r PATH', '--require PATH') { |v| options[:require_path] = v }
        o.on('-C PATH', '--config PATH') { |v| options[:config_path] = v }
        o.on('-L PATH', '--logfile PATH') { |v| options[:logfile] = v }
        o.on('-q QUEUE', '--queue QUEUE') { |v| options[:queues].concat(parse_queue_weight(v)) }
      end.parse!(argv.dup)

      options
    end

    def self.parse_queue_weight(value)
      name, weight = value.split(',')
      Array.new([weight.to_i, 1].max, name)
    end

    # Boots one OS process fully: applies config, requires app code, and
    # blocks running the Launcher loop until a stop signal is handled.
    # `argv` is parsed independently per call so a swarm parent can boot each
    # forked child with the exact same flags it was started with.
    def run(argv)
      options = self.class.parse(argv)
      file_config = ConfigLoader.load(options[:config_path])

      Cogworker.server_process!
      Cogworker.config.concurrency = options[:concurrency] || file_config[:concurrency]&.to_i || Cogworker.config.concurrency
      Cogworker.config.queues = options[:queues].any? ? options[:queues] : (file_config[:queues] || Cogworker.config.queues)

      redirect_logfile(options[:logfile]) if options[:logfile]
      require_app_code(options[:require_path]) if options[:require_path]

      Launcher.new.run
    end

    private

    def redirect_logfile(path)
      Cogworker.logger = Logging.default_logger(File.open(path, 'a'))
    end

    def require_app_code(path)
      expanded = File.expand_path(path)
      if File.directory?(expanded)
        require File.join(expanded, 'config/environment')
      else
        require expanded
      end
    end
  end
end
