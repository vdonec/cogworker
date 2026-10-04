# frozen_string_literal: true

require 'spec_helper'
require 'tempfile'
require 'stringio'

# A real, separate OS process — deliberately not just an in-process
# Heartbeat/Manager pair like other specs use. The one thing this test
# actually needs to prove (a remote 'stop' message ends the *process*, not
# just the Manager) can only be observed by watching an OS process actually
# exit; `Heartbeat#dispatch`'s 'stop' path calls `::Process.exit!`, and
# calling that in-process here would kill the rspec run itself.
RSpec.describe 'Cogworker::Heartbeat remote stop (end-to-end, real OS process)' do
  let(:lib) { File.expand_path('../../lib', __dir__) }

  after do
    next unless @pid

    ::Process.kill('KILL', @pid)
    ::Process.wait(@pid)
  rescue Errno::ESRCH, Errno::ECHILD
    nil
  end

  # `Process.kill(0, pid)` is the wrong tool here: a child we spawned
  # ourselves that has already exited stays a *zombie* — still "present" as
  # far as `kill(0, ...)` is concerned — until something actually reaps it,
  # so that check would never observe the exit at all. `waitpid` with
  # `WNOHANG` both checks *and* reaps in the same call: non-nil the moment
  # the child has terminated, `nil` while it's still running.
  def child_exited?
    !::Process.waitpid(@pid, ::Process::WNOHANG).nil?
  rescue Errno::ECHILD
    true # already reaped by an earlier call
  end

  it 'actually terminates the OS process — it previously only quiesced the Manager forever, leaving the ' \
     'process alive and still heartbeating with no way back to work short of a real kill' do
    script = <<~RUBY
      require 'cogworker'
      Cogworker.config.redis = { url: #{TEST_REDIS_URL.inspect} }
      manager = Cogworker::Manager.new
      manager.start!
      Cogworker::Heartbeat.new(manager).start!
      sleep
    RUBY

    Tempfile.create(%w[heartbeat_remote_stop .rb]) do |f|
      f.write(script)
      f.flush

      @pid = ::Process.spawn(RbConfig.ruby, '-I', lib, f.path, out: File::NULL, err: File::NULL)

      identity = wait_for(timeout: 8) { Cogworker::ProcessSet.new.find { |p| p['pid'] == @pid }&.identity }
      expect(identity).not_to be_nil, 'child process never published its heartbeat presence'
      expect(child_exited?).to be(false)

      # Pub/sub doesn't queue messages: published before the child's
      # SUBSCRIBE is live (its first beat, which makes it show up above,
      # happens before the subscriber thread even starts), 'stop' would
      # just be dropped.
      channel = "cogworker:signal:#{identity}"
      wait_for(timeout: 8) { Cogworker.config.redis { |c| c.pubsub(:numsub, channel) }.last.to_i == 1 }
      Cogworker::ProcessSet.new.find { |p| p.identity == identity }.stop!

      wait_for(timeout: 8) { child_exited? } # raises if it never exits — that's the actual assertion here
      @pid = nil

      # `cleanup_presence!` ran (and completed) before the process exited.
      expect(Cogworker::ProcessSet.new.map(&:identity)).not_to include(identity)
    end
  end
end

RSpec.describe Cogworker::Heartbeat do
  let(:manager) { Cogworker::Manager.new }

  it 'stop! returns promptly with the pub/sub subscriber blocked in its read (it used to hang forever on ' \
     'redis-rb 4.x, where unsubscribe from another thread waits on the monitor the subscriber holds)' do
    heartbeat = described_class.new(manager)
    heartbeat.start!
    channel = "cogworker:signal:#{Cogworker.identity}"
    wait_for { Cogworker.config.redis { |c| c.pubsub(:numsub, channel) }.last.to_i == 1 }

    finished = Thread.new { heartbeat.stop! }
    expect(finished.join(5)).not_to be_nil
    expect(heartbeat.instance_variable_get(:@signal_thread)).not_to be_alive
    wait_for { Cogworker.config.redis { |c| c.pubsub(:numsub, channel) }.last.to_i.zero? }
  end

  it "keeps an in-flight periodic run's running lock alive on every beat — from the process's own record, " \
     'not cogworker:workers (which a failover can lose)' do
    key = 'periodic:running:pj1'
    Cogworker.config.redis { |c| c.set(key, 'jid1', ex: 5) }
    manager.job_started(JSON.generate('class' => 'X', 'jid' => 'jid1', 'periodic_pjid' => 'pj1'))

    described_class.new(manager).send(:beat)

    expect(Cogworker.config.redis { |c| c.ttl(key) }).to be > 5
  end

  it 'keeps beating after a failed beat instead of letting the thread die' do
    heartbeat = described_class.new(manager)
    calls = 0
    allow(heartbeat).to receive(:beat) do
      calls += 1
      raise Redis::CannotConnectError, 'blip' if calls == 1

      throw :done if calls == 2
    end
    allow(heartbeat).to receive(:sleep)

    catch(:done) { heartbeat.send(:beat_loop) }
    expect(calls).to eq(2)
  end

  it "still refreshes the other in-flight periodic locks when one in-flight entry can't be read" do
    key = 'periodic:running:pj2'
    Cogworker.config.redis { |c| c.set(key, 'jid2', ex: 5) }
    manager.job_started('{not json')
    manager.job_started(JSON.generate('jid' => 'jid2', 'periodic_pjid' => 'pj2'))
    allow(Cogworker).to receive(:logger).and_return(Cogworker::Logging.default_logger(StringIO.new))

    described_class.new(manager).send(:beat)

    expect(Cogworker.config.redis { |c| c.ttl(key) }).to be > 5
  end

  describe 'start! with Redis unreachable' do
    subject(:heartbeat) { described_class.new(manager) }

    before do
      allow(heartbeat).to receive(:sleep)
      allow(Cogworker).to receive(:logger).and_return(Cogworker::Logging.default_logger(StringIO.new))
    end

    after { heartbeat.stop! }

    it 'keeps retrying the first beat, and only starts its threads once one succeeds' do
      calls = 0
      allow(heartbeat).to receive(:beat) { raise Redis::CannotConnectError, 'down' if (calls += 1) < 3 }

      expect(heartbeat.start!).to be(true)
      expect(calls).to eq(3)
      expect(heartbeat.instance_variable_get(:@beat_thread)).to be_alive
    end

    it 'gives up, starting nothing, as soon as abort_if says so' do
      allow(heartbeat).to receive(:beat).and_raise(Redis::CannotConnectError, 'down')

      expect(heartbeat.start!(abort_if: -> { true })).to be(false)
      expect(heartbeat.instance_variable_get(:@beat_thread)).to be_nil
    end
  end

  it "stamps its last beat with this host's clock where Redis refuses TIME, instead of never beating" do
    heartbeat = described_class.new(manager)
    conn = double
    allow(conn).to receive(:time).and_raise(Redis::CommandError, "ERR unknown command 'TIME'")

    expect(heartbeat.send(:redis_now, conn)).to be_within(2).of(Time.now.to_i)
  end

  it 'still beats (and so a process can start) when a shared registry key holds the wrong type' do
    Cogworker.config.redis do |c|
      c.set('cogworker:inprogress_identities', 'x')
      c.set('cogworker:last_beat', 'x')
      c.set('cogworker:processes', 'x')
    end
    log = StringIO.new
    allow(Cogworker).to receive(:logger).and_return(Cogworker::Logging.default_logger(log))
    heartbeat = described_class.new(manager)

    expect(heartbeat.start!).to be(true)
    expect(Cogworker.config.redis { |c| c.exists?("cogworker:process:#{Cogworker.identity}") }).to be(true)
    expect(log.string).to include('process registry not written') # (written in any fetch mode)
  ensure
    heartbeat&.stop!
  end

  it "puts back a still-running until_executed run's lock that lapsed while Redis was away, " \
     "but never takes another's" do
    manager.job_started(JSON.generate('jid' => 'mine', 'periodic_pjid' => 'pjr', 'periodic_until_executed' => true))
    manager.job_started(JSON.generate('jid' => 'mine2', 'periodic_pjid' => 'pjo', 'periodic_until_executed' => true))
    Cogworker.config.redis { |c| c.set('periodic:running:pjo', 'newer-run') }
    heartbeat = described_class.new(manager)
    heartbeat.instance_variable_set(:@beat_failed, true) # Redis was away: the previous beat failed

    heartbeat.send(:beat_safely)

    expect(Cogworker.config.redis { |c| [c.get('periodic:running:pjr'), c.get('periodic:running:pjo')] })
      .to eq(%w[mine newer-run])
  end

  it "never brings back a lock that was released — in normal operation, or once the job's perform has returned" do
    running = JSON.generate('jid' => 'r1', 'periodic_pjid' => 'pjn', 'periodic_until_executed' => true)
    finished = JSON.generate('jid' => 'f1', 'periodic_pjid' => 'pjf', 'periodic_until_executed' => true)
    manager.job_started(running)
    manager.job_started(finished)
    manager.job_performed(finished) # its middleware released the lock; not acknowledged yet
    heartbeat = described_class.new(manager)

    heartbeat.send(:beat_safely) # a normal beat: nothing to re-take
    heartbeat.instance_variable_set(:@beat_failed, true)
    heartbeat.send(:beat_safely) # after an outage: only jobs still performing

    expect(Cogworker.config.redis { |c| [c.get('periodic:running:pjn'), c.get('periodic:running:pjf')] })
      .to eq(['r1', nil])
  end

  it "lists the process's own queues in cogworker:queues on every beat, even while they're empty" do
    Cogworker.config.queues = %w[default default low]

    described_class.new(Cogworker::Manager.new).send(:beat)

    expect(Cogworker.config.redis { |c| c.smembers('cogworker:queues') }).to contain_exactly('default', 'low')
  end

  it 'stamps its queues as live on every beat' do
    described_class.new(manager).send(:beat)

    expect(Cogworker.config.redis { |c| c.zscore('cogworker:live_queues', 'default') }).to be_within(5)
      .of(Cogworker.config.redis { |c| c.time.first })
  end
end
