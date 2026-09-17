# frozen_string_literal: true

require 'spec_helper'
require 'tempfile'
require 'timeout'
require 'set'

# These spawn the real exe/cogworkerswarm binary as a subprocess (Swarm#run
# never returns on its own — it's the process supervisor loop), so they're
# slower and touch real OS processes/signals, not just in-process objects.
RSpec.describe 'cogworkerswarm end-to-end', :swarm do
  let(:exe) { File.expand_path('../../exe/cogworkerswarm', __dir__) }
  let(:lib) { File.expand_path('../../lib', __dir__) }

  around do |example|
    Tempfile.create(%w[swarm_init .rb]) do |init_file|
      init_file.write(<<~RUBY)
        require 'cogworker'
        Cogworker.configure_server { |c| c.redis = { url: #{TEST_REDIS_URL.inspect} } }
        class SwarmSmokeJob
          include Cogworker::Worker
          def perform(n)
            Cogworker.config.redis { |c| c.rpush('swarm:results', n) }
          end
        end
      RUBY
      init_file.flush
      @init_path = init_file.path
      example.run
    end
  end

  after do |example|
    if example.exception && @log_path && File.exist?(@log_path)
      warn "--- swarm log (#{@log_path}) ---"
      warn File.read(@log_path)
      warn '--- end swarm log ---'
    end
    kill_swarm
  end

  # Signals the whole process group (`-@pid`), not just the swarm supervisor
  # itself: the supervisor's own worker children live in that same group
  # (see spawn_swarm's `pgroup: true`), and if graceful shutdown (TERM ->
  # Swarm relays STOP -> children drain) doesn't finish inside the timeout —
  # plausible on a loaded CI runner — a bare `KILL` on just the supervisor's
  # pid would leave those already-forked children running as orphans,
  # permanently connected to the shared test Redis db and silently stealing
  # jobs pushed by every later example in the suite.
  def kill_swarm
    return unless @pid

    begin
      ::Process.kill('-TERM', @pid)
      Timeout.timeout(5) { ::Process.wait(@pid) }
    rescue Errno::ESRCH, Errno::ECHILD, Timeout::Error
      begin
        ::Process.kill('-KILL', @pid)
        ::Process.wait(@pid)
      rescue Errno::ESRCH, Errno::ECHILD
        nil
      end
    end
  end

  def spawn_swarm(count:, phased: false, concurrency: 2)
    env = { 'COGWORKER_COUNT' => count.to_s, 'PHASED_RESTART' => phased.to_s }
    @log_path = File.join(Dir.tmpdir, "cogworker_swarm_log_#{::Process.pid}_#{rand(1_000_000)}.log")
    @pid = ::Process.spawn(env, RbConfig.ruby, '-I', lib, exe, '-r', @init_path, '-c', concurrency.to_s,
                           out: @log_path, err: [:child, :out], pgroup: true)
  end

  def child_pids
    `pgrep -P #{@pid}`.split.map(&:to_i)
  end

  it 'forks COGWORKER_COUNT children that together process pushed jobs' do
    Cogworker.config.redis { |c| c.del('swarm:results') }
    spawn_swarm(count: 3)

    wait_for(timeout: 8) { child_pids.size == 3 }

    stub_const('SwarmSmokeJob', Class.new { include Cogworker::Worker })
    10.times { |i| SwarmSmokeJob.perform_async(i) }

    wait_for(timeout: 8) { Cogworker.config.redis { |c| c.llen('swarm:results') } == 10 }

    identities = wait_for(timeout: 8) do
      found = Cogworker.config.redis { |c| c.smembers('cogworker:processes') }
      found if found.size == 3
    end
    expect(identities.size).to eq(3)
  end

  it 'never drops to zero children during a PHASED_RESTART=true cycle' do
    spawn_swarm(count: 2, phased: true)
    wait_for(timeout: 8) { child_pids.size == 2 }
    original = child_pids

    ::Process.kill('USR2', @pid)

    # One continuous poll from signal to completion, tracking the lowest
    # capacity seen along the way, instead of a separately-guessed "watch
    # for N seconds" window followed by a separately-guessed "wait up to M
    # seconds for completion" — those two arbitrary windows could either
    # miss a real dip (window too short) or fail a healthy restart that's
    # just running slow on a loaded CI box (window too long). The 30s bound
    # here is a single honest backstop for "this is actually stuck", not a
    # timing guess about how long a phased restart normally takes.
    min_seen = 2
    wait_for(timeout: 30) do
      min_seen = [min_seen, child_pids.size].min
      child_pids.size == 2 && child_pids.to_set != original.to_set
    end

    expect(min_seen).to be >= 1
  end
end
