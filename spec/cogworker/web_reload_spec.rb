# frozen_string_literal: true

require 'spec_helper'

# COGWORKER_RELOAD must be set *before* `require 'cogworker'` (Zeitwerk's
# `enable_reloading` has to run before `setup`), so this can only be
# exercised in a separate process, not by toggling a flag inside the
# already-running spec suite.
RSpec.describe 'Cogworker::Web reload (COGWORKER_RELOAD=true)' do
  it 'handles repeated requests, each triggering a full Zeitwerk reload, without NameError' do
    lib = File.expand_path('../../lib', __dir__)
    script = <<~RUBY
      require 'cogworker'
      Cogworker.config.redis = { url: #{TEST_REDIS_URL.inspect} }
      Cogworker::Web # bare reference, not `require 'cogworker/web'` — see CLAUDE.md's Zeitwerk section

      3.times do |i|
        env = Rack::MockRequest.env_for('/busy')
        status, _headers, body = Cogworker::Web.call(env)
        raise "request \#{i} failed: \#{status}\\n\#{body.reduce(:+)}" unless status == 200
      end
      puts 'ALL_REQUESTS_OK'
    RUBY

    result = IO.popen(
      { 'COGWORKER_RELOAD' => 'true' },
      [RbConfig.ruby, '-I', lib, '-rrack/mock', '-e', script],
      err: %i[child out], &:read
    )

    expect($?).to be_success, "child process failed:\n#{result}" # rubocop:disable Style/SpecialGlobalVars
    expect(result).to include('ALL_REQUESTS_OK')
  end

  it 'survives concurrent requests each triggering a reload, without Zeitwerk::SetupRequired' do
    # `.call` reloads on *every* request when COGWORKER_RELOAD=true — with
    # several Puma threads serving one page (the tab's own poll_div fragment
    # plus the global stats bar's, both polling independently), two threads
    # can call `Cogworker::LOADER.reload` at the same instant.
    # `Zeitwerk::Loader#reload` isn't reentrant: without `Web::RELOAD_MUTEX`
    # serializing it, this reliably reproduces `Zeitwerk::SetupRequired`
    # within a handful of concurrent iterations — and once raised, the
    # loader stays wedged (every later request keeps re-raising it) until
    # the process restarts, which is exactly what happened for real.
    lib = File.expand_path('../../lib', __dir__)
    script = <<~RUBY
      require 'cogworker'
      Cogworker.config.redis = { url: #{TEST_REDIS_URL.inspect} }
      # Captured *once*, matching what `Rack::URLMap`/`run Cogworker::Web`
      # actually does in production (see CLAUDE.md: Rack holds one object
      # reference forever, it never re-resolves the `Cogworker::Web`
      # constant per request) — a fresh `Cogworker::Web` constant lookup on
      # every call, unlike real usage, would itself race against another
      # thread's in-flight `unload` and raise a spurious NameError that has
      # nothing to do with the actual bug under test here.
      web = Cogworker::Web

      errors = Queue.new
      threads = 8.times.map do
        Thread.new do
          20.times do
            env = Rack::MockRequest.env_for('/busy')
            status, _headers, body = web.call(env)
            errors << "status \#{status}: \#{body.reduce(:+)}" unless status == 200
          rescue StandardError => e
            errors << "\#{e.class}: \#{e.message}"
          end
        end
      end
      threads.each(&:join)

      if errors.empty?
        puts 'ALL_REQUESTS_OK'
      else
        puts errors.size.times.map { errors.pop }.uniq.join("\\n")
      end
    RUBY

    result = IO.popen(
      { 'COGWORKER_RELOAD' => 'true' },
      [RbConfig.ruby, '-I', lib, '-rrack/mock', '-e', script],
      err: %i[child out], &:read
    )

    expect($?).to be_success, "child process failed:\n#{result}" # rubocop:disable Style/SpecialGlobalVars
    expect(result).to include('ALL_REQUESTS_OK'), "concurrent requests raised:\n#{result}"
  end
end
