# frozen_string_literal: true

module Cogworker
  class Web
    # Reads a built-in view template by name. An extension that wants its
    # own template file can use the same pattern (read the file itself,
    # then hand `erb` the resulting String) — `Action#erb` accepts either a
    # Symbol (looked up here) or a raw ERB-source String directly.
    module Views
      VIEWS_PATH = File.join(__dir__, 'views')

      class << self
        def read(name)
          cache[name] ||= File.read(File.join(VIEWS_PATH, "#{name}.erb"))
        end

        private

        def cache
          @cache ||= {}
        end
      end
    end
  end
end
