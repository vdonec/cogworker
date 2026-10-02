# frozen_string_literal: true

require 'spec_helper'
require 'json'
require 'stringio'

RSpec.describe Cogworker::ReliableFetch do
  def push(queue, jid)
    raw = JSON.generate('jid' => jid, 'class' => 'X', 'queue' => queue, 'args' => [])
    Cogworker.config.redis { |c| c.lpush("cogworker:queue:#{queue}", raw) }
    raw
  end

  def in_progress(identity = Cogworker.identity)
    Cogworker.config.redis { |c| c.lrange("cogworker:inprogress:#{identity}", 0, -1) }
  end

  def queue_jids(queue = 'default')
    Cogworker.config.redis { |c| c.lrange("cogworker:queue:#{queue}", 0, -1) }.map { |raw| JSON.parse(raw)['jid'] }
  end

  it 'moves the fetched job onto this process\'s in-progress list, and acknowledge removes it' do
    raw = push('default', 'a')
    fetch = described_class.new(%w[default])

    work = fetch.retrieve_work

    expect(work.queue).to eq('default')
    expect(work.raw_job).to eq(raw)
    expect(queue_jids).to be_empty
    expect(in_progress).to eq([raw])

    fetch.acknowledge(work)
    expect(in_progress).to be_empty
  end

  it 'takes from whichever of its queues has work, and never from a paused one' do
    push('default', 'paused-job')
    push('low', 'low-job')
    Cogworker::Queue.new('default').pause!

    work = described_class.new(%w[default low]).retrieve_work

    expect(work.queue).to eq('low')
    expect(queue_jids('default')).to eq(['paused-job'])
  end

  it 'returns nil after a short pause when every queue is empty' do
    stub_const('Cogworker::ReliableFetch::EMPTY_POLL_INTERVAL', 0.05)

    started = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
    expect(described_class.new(%w[default low]).retrieve_work).to be_nil
    expect(::Process.clock_gettime(::Process::CLOCK_MONOTONIC) - started).to be >= 0.05
  end

  describe '.requeue_in_progress' do
    it 'puts every job back on its own queue, oldest first, so they are the next ones popped' do
      fetch = described_class.new(%w[default low])
      push('default', 'old')
      push('default', 'new')
      push('low', 'low')
      3.times { fetch.retrieve_work }

      expect(described_class.requeue_in_progress(Cogworker.identity)).to eq(3)

      expect(in_progress).to be_empty
      expect(queue_jids('default')).to eq(%w[new old]) # RPOP takes from the right: 'old' runs first
      expect(queue_jids('low')).to eq(['low'])
    end

    it 'sends a payload whose queue cannot be read to the default queue (the Processor then buries it)' do
      Cogworker.config.redis { |c| c.lpush("cogworker:inprogress:#{Cogworker.identity}", '{not json') }

      described_class.requeue_in_progress(Cogworker.identity)

      expect(Cogworker.config.redis { |c| c.lrange('cogworker:queue:default', 0, -1) }).to eq(['{not json'])
    end
  end

  describe '.recover_orphans' do
    before do
      Cogworker.config.redis do |c|
        c.lpush('cogworker:inprogress:dead-host:1:abc', JSON.generate('jid' => 'orphan', 'queue' => 'default'))
        c.lpush('cogworker:inprogress:live-host:2:def', JSON.generate('jid' => 'running', 'queue' => 'default'))
        c.set('cogworker:process:live-host:2:def', '1')
        c.lpush("cogworker:inprogress:#{Cogworker.identity}", JSON.generate('jid' => 'mine', 'queue' => 'default'))
      end
    end

    it "requeues only the lists of processes whose heartbeat is gone — never a live process's, nor its own" do
      log = StringIO.new
      allow(Cogworker).to receive(:logger).and_return(Cogworker::Logging.default_logger(log))

      expect(described_class.recover_orphans).to eq(1)

      expect(queue_jids).to eq(['orphan'])
      expect(in_progress('live-host:2:def').size).to eq(1)
      expect(in_progress.size).to eq(1)
      expect(log.string).to include('requeued 1 job(s) left in progress by dead process dead-host:1:abc')
    end
  end

  describe 'Manager integration' do
    after { @manager&.stop!(timeout: 1) }

    it 'is the default fetch, and leaves nothing in progress once jobs have run' do
      done = Queue.new
      stub_const('ReliableEchoJob', Class.new { include Cogworker::Worker })
      ReliableEchoJob.define_method(:perform) { done << :ok }
      ReliableEchoJob.perform_async

      @manager = Cogworker::Manager.new
      expect(@manager.fetch_class).to eq(described_class)
      @manager.start!

      expect(wait_for { done.pop(true) rescue nil }).to eq(:ok) # rubocop:disable Style/RescueModifier
      wait_for { in_progress.empty? }
    end

    it 'falls back to BasicFetch, with a warning, on a Redis too old for LMOVE' do
      allow(described_class).to receive(:supported?).and_return(false)
      log = StringIO.new
      allow(Cogworker).to receive(:logger).and_return(Cogworker::Logging.default_logger(log))

      expect(Cogworker::Manager.new.fetch_class).to eq(Cogworker::BasicFetch)
      expect(log.string).to include('falling back to :basic')
    end

    it 'detects a real, current Redis as supported' do
      expect(described_class.supported?).to be(true)
    end

    %i[reliable basic].each do |mode|
      it "requeues a job still running when the shutdown drain times out (fetch: #{mode})" do
        Cogworker.config.fetch = mode
        gate = Queue.new
        started = Queue.new
        stub_const('StuckJob', Class.new { include Cogworker::Worker })
        StuckJob.define_method(:perform) do
          started << :yes
          gate.pop
        end
        jid = StuckJob.perform_async

        manager = Cogworker::Manager.new
        manager.start!
        wait_for { started.pop(true) rescue nil } # rubocop:disable Style/RescueModifier
        manager.stop!(timeout: 0.2)

        expect(queue_jids).to eq([jid])
        expect(in_progress).to be_empty
      ensure
        gate << :go
        manager&.stop!(timeout: 1)
      end
    end
  end
end

RSpec.describe Cogworker::BasicFetch, '.requeue_in_progress' do
  it 'requeues every readable in-flight entry even when another one cannot be read' do
    identity = Cogworker.identity
    Cogworker.config.redis do |c|
      c.hset("cogworker:workers:#{identity}", 't1', '{not json')
      c.hset("cogworker:workers:#{identity}", 't2',
             JSON.generate('queue' => 'default', 'payload' => { 'jid' => 'ok', 'queue' => 'default' }))
    end
    allow(Cogworker).to receive(:logger).and_return(Cogworker::Logging.default_logger(StringIO.new))

    expect(described_class.requeue_in_progress(identity)).to eq(1)
    expect(queued_jobs.map { |j| j['jid'] }).to eq(['ok'])
  end
end

# A real child OS process, killed with SIGKILL mid-job: the one scenario
# reliable fetch exists for, and the one that can't be faked in-process.
RSpec.describe 'ReliableFetch surviving a killed process (end-to-end, real OS process)' do
  let(:lib) { File.expand_path('../../lib', __dir__) }

  after do
    ::Process.kill('KILL', @pid) if @pid
    ::Process.wait(@pid) if @pid
  rescue Errno::ESRCH, Errno::ECHILD
    nil
  end

  it "puts the killed process's in-flight job back on its queue once its heartbeat is gone" do
    script = <<~RUBY
      require 'cogworker'
      Cogworker.config.redis = { url: #{TEST_REDIS_URL.inspect} }
      Cogworker.config.concurrency = 1
      class KilledMidJob
        include Cogworker::Worker
        def perform
          Cogworker.config.redis { |c| c.set('e2e:started', Cogworker.identity) }
          sleep 60
        end
      end
      Cogworker::Launcher.new.run
    RUBY
    jid = Cogworker::Client.push('class' => 'KilledMidJob', 'args' => [])

    @pid = ::Process.spawn(RbConfig.ruby, '-I', lib, '-e', script, out: File::NULL, err: File::NULL)
    identity = wait_for(timeout: 15) { Cogworker.config.redis { |c| c.get('e2e:started') } }
    ::Process.kill('KILL', @pid)
    ::Process.wait(@pid)
    @pid = nil

    expect(Cogworker.config.redis { |c| c.llen('cogworker:queue:default') }).to eq(0)
    expect(Cogworker.config.redis { |c| c.llen("cogworker:inprogress:#{identity}") }).to eq(1)

    # What the heartbeat TTL expiring does on its own, a minute later.
    Cogworker.config.redis { |c| c.del("cogworker:process:#{identity}") }
    Cogworker::ReliableFetch.recover_orphans

    requeued = Cogworker.config.redis { |c| c.lrange('cogworker:queue:default', 0, -1) }
    expect(requeued.map { |raw| JSON.parse(raw)['jid'] }).to eq([jid])
  end
end
