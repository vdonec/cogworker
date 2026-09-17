# frozen_string_literal: true

require_relative 'lib/cogworker/version'

Gem::Specification.new do |spec|
  spec.name          = 'cogworker'
  spec.version       = Cogworker::VERSION
  spec.authors       = ['vdonec']
  spec.summary       = 'Redis-backed background job processing: worker DSL, periodic scheduling, and process introspection'
  spec.license       = 'MIT'
  spec.homepage      = 'https://github.com/vdonec/cogworker'
  spec.metadata['source_code_uri'] = spec.homepage
  spec.required_ruby_version = '>= 3.1'

  spec.files = Dir['lib/**/*.rb', 'lib/**/*.lua', 'lib/**/*.js', 'lib/**/*.css', 'exe/*']
  spec.bindir = 'exe'
  spec.executables = Dir['exe/*'].map { |f| File.basename(f) }
  spec.require_paths = ['lib']

  spec.add_dependency 'connection_pool', '~> 2.4'
  spec.add_dependency 'fugit', '~> 1.9'
  spec.add_dependency 'logger', '~> 1.6'
  spec.add_dependency 'rack', '>= 2.2'
  spec.add_dependency 'rack-session', '>= 1.0'
  spec.add_dependency 'redis', '>= 4.8', '< 6'
  spec.add_dependency 'zeitwerk', '~> 2.6'

  spec.add_development_dependency 'capybara', '~> 3.40'
  spec.add_development_dependency 'cuprite', '~> 0.15'
  spec.add_development_dependency 'puma', '~> 6.4'
  spec.add_development_dependency 'rackup', '~> 2.1'
  spec.add_development_dependency 'rspec', '~> 3.13'
  spec.add_development_dependency 'rubocop', '~> 1.65'
end
