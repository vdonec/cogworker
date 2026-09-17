# frozen_string_literal: true

module Cogworker
  class Web
    # Compiles a Sinatra-style path pattern (`/queues/:name`) into a Regexp
    # with named captures, and matches request paths against it.
    module Router
      module_function

      def compile(pattern)
        return %r{\A/\z} if pattern == '/'

        source = pattern.split('/').map do |segment|
          segment.start_with?(':') ? "(?<#{segment[1..]}>[^/]+)" : Regexp.escape(segment)
        end.join('/')
        Regexp.new("\\A#{source}\\z")
      end

      def match(regexp, path)
        m = regexp.match(path)
        return nil unless m

        m.named_captures
      end
    end
  end
end
