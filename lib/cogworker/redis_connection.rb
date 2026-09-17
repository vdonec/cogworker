# frozen_string_literal: true

require 'redis'
require 'connection_pool'

module Cogworker
  # Builds a fork-safe ConnectionPool of redis-rb clients from either a
  # `url:` or separate `host:`/`port:`/`password:`/`db:` keys. redis-rb
  # connects lazily on first command, so building the pool before a
  # cogworkerswarm fork is safe as long as nothing issues a command yet.
  module RedisConnection
    module_function

    def create(options = {})
      options = options.dup
      size = options.delete(:size) || options.delete(:concurrency) || 5
      client_opts = client_options(options)

      ConnectionPool.new(size: size, timeout: options[:pool_timeout] || 5) do
        ::Redis.new(client_opts)
      end
    end

    def client_options(options)
      if options[:url]
        { url: options[:url] }
      else
        {
          host: options[:host] || 'localhost',
          port: options[:port] || 6379,
          password: options[:password],
          db: (options[:db] || 0).to_i
        }.compact
      end
    end
  end
end
