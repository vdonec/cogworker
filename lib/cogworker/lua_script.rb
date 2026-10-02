# frozen_string_literal: true

require 'digest/sha1'

module Cogworker
  # Runs a Lua script by its SHA1 (EVALSHA) instead of shipping the whole
  # source on every call, falling back to EVAL — which also loads it into
  # the server's script cache for next time — on NOSCRIPT (first use, a
  # restarted or failed-over server, SCRIPT FLUSH). Every script in this
  # gem goes through here.
  module LuaScript
    SHAS = {} # source => sha1; memoized, the source strings are frozen constants
    SHAS_MUTEX = Mutex.new

    module_function

    def run(conn, source, keys: [], argv: [])
      begin
        return conn.evalsha(sha(source), keys: keys, argv: argv)
      rescue Redis::CommandError => e
        raise unless e.message.start_with?('NOSCRIPT')
      end
      conn.eval(source, keys: keys, argv: argv)
    end

    def sha(source)
      SHAS_MUTEX.synchronize { SHAS[source] ||= Digest::SHA1.hexdigest(source) }
    end
  end
end
