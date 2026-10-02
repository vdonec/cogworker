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

  it 'moves the fetched job onto this process\'s in-progress list, and acknowledge removes it', :reliable_fetch do
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

  it 'takes from whichever of its queues has work, and never from a paused one', :reliable_fetch do
    push('default', 'paused-job')
    push('low', 'low-job')
    Cogworker::Queue.new('default').pause!

    work = described_class.new(%w[default low]).retrieve_work

    expect(work.queue).to eq('low')
    expect(queue_jids('default')).to eq(['paused-job'])
  end

  it 'backs off while its queues stay empty — doubling up to fetch_idle_max_interval, jittered — ' \
     'and starts over once it finds a job', :reliable_fetch do
    fetch = described_class.new(%w[default low])
    pauses = []
    allow(fetch).to receive(:interruptible_sleep) { |s| pauses << s }

    4.times { expect(fetch.retrieve_work).to be_nil }
    push('default', 'a')
    fetch.retrieve_work
    fetch.retrieve_work

    [0.25, 0.5, 1.0, 1.0, 0.25].zip(pauses).each do |interval, pause|
      expect(pause).to be_between(interval * 0.75, interval)
    end
  end

  it 'never pauses longer than a smaller fetch_idle_max_interval', :reliable_fetch do
    Cogworker.config.fetch_idle_max_interval = 0.1
    fetch = described_class.new(%w[default low])
    pauses = []
    allow(fetch).to receive(:interruptible_sleep) { |s| pauses << s }

    3.times { fetch.retrieve_work }

    expect(pauses.size).to eq(3)
    expect(pauses).to all(be <= 0.1)
  end

  it 'blocks on the server (BLMOVE) instead of polling when it has a single queue, and still lands in progress', :reliable_fetch do
    fetch = described_class.new(%w[default default])
    expect(fetch).not_to receive(:interruptible_sleep)
    pusher = Thread.new do
      sleep 0.3
      push('default', 'late')
    end

    started = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
    work = fetch.retrieve_work
    pusher.join

    expect(JSON.parse(work.raw_job)['jid']).to eq('late')
    expect(::Process.clock_gettime(::Process::CLOCK_MONOTONIC) - started).to be < 1.5
    expect(in_progress.size).to eq(1)
  end

  it 'cuts an idle pause short as soon as shutdown begins', :reliable_fetch do
    stopping = false
    Cogworker.config.fetch_idle_max_interval = 30
    fetch = described_class.new(%w[default low], stopping: -> { stopping })
    fetch.instance_variable_set(:@idle_interval, 30)
    Thread.new do
      sleep 0.3
      stopping = true
    end

    started = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
    fetch.retrieve_work
    expect(::Process.clock_gettime(::Process::CLOCK_MONOTONIC) - started).to be < 1.5
  end

  it 'runs the fetch script by hash once it is cached, instead of resending its text every poll', :reliable_fetch do
    fetch = described_class.new(%w[default low])
    allow(fetch).to receive(:interruptible_sleep)
    Cogworker.config.redis { |c| c.script(:flush) }
    fetch.retrieve_work # NOSCRIPT -> EVAL, which caches it

    expect(Cogworker.config.redis { |c| c.script(:exists, described_class::FETCH_SCRIPT_SHA) }).to be(true)
  end

  describe '.requeue_in_progress' do
    it 'puts every job back on its own queue, oldest first, so they are the next ones popped', :reliable_fetch do
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

  describe 'requeueing an until_executed periodic run' do
    let(:job) do
      JSON.generate('jid' => 'run1', 'queue' => 'default', 'periodic_pjid' => 'pj',
                    'periodic_until_executed' => true)
    end
    let(:lock) { 'periodic:running:pj' }

    before { Cogworker.config.redis { |c| c.lpush("cogworker:inprogress:#{Cogworker.identity}", job) } }

    def lock_state = Cogworker.config.redis { |c| [c.get(lock), c.ttl(lock)] }

    it 're-takes a lapsed lock for the requeued run, so the ticker cannot start the next slot alongside it' do
      described_class.requeue_in_progress(Cogworker.identity)

      owner, ttl = lock_state
      expect(owner).to eq('run1')
      expect(ttl).to be > Cogworker::Periodic::RunningLock.active_ttl
    end

    it 're-takes the lock on give_back too, not only on recovery' do
      fetch = described_class.new(%w[default])
      described_class.new(%w[default]) # (same identity)
      work = Cogworker::BasicFetch::UnitOfWork.new('default', job)

      fetch.give_back(work)

      expect(lock_state.first).to eq('run1')
      expect(queue_jids).to eq(['run1'])
    end

    it "extends the run's own lock, and leaves alone one a newer run holds" do
      Cogworker.config.redis { |c| c.set(lock, 'run1', ex: 30) }
      described_class.requeue_in_progress(Cogworker.identity)
      expect(lock_state.last).to be > Cogworker::Periodic::RunningLock.active_ttl

      Cogworker.config.redis do |c|
        c.set(lock, 'newer', ex: 30)
        c.lpush("cogworker:inprogress:#{Cogworker.identity}", job)
      end
      described_class.requeue_in_progress(Cogworker.identity)
      expect(lock_state.first).to eq('newer')
      expect(lock_state.last).to be <= 30
    end

    it 'keeps an active lock alive longer than it takes to recover a dead process\'s job' do
      Cogworker.config.orphan_threshold = 900
      expect(Cogworker::Periodic::RunningLock.active_ttl)
        .to be > Cogworker.config.orphan_threshold + Cogworker::Scheduled::ORPHAN_CHECK_INTERVAL
    end
  end

  describe '.reconcile' do
    let(:raw) { JSON.generate('jid' => 'stuck', 'queue' => 'default') }

    before do
      Cogworker.config.redis { |c| c.lpush("cogworker:inprogress:#{Cogworker.identity}", raw) }
      allow(Cogworker).to receive(:logger).and_return(Cogworker::Logging.default_logger(StringIO.new))
    end

    it 'requeues an own in-progress job no thread is running, once it has been seen stray twice in a row' do
      strays = described_class.reconcile(Cogworker.identity, [])
      expect(strays).to eq([raw])
      expect(queue_jids).to be_empty

      expect(described_class.reconcile(Cogworker.identity, strays)).to be_empty
      expect(queue_jids).to eq(['stuck'])
      expect(in_progress).to be_empty
    end

    it 'leaves alone a job a processor thread is actually running' do
      Cogworker.config.redis do |c|
        c.hset("cogworker:workers:#{Cogworker.identity}", 't1',
               JSON.generate('queue' => 'default', 'payload' => { 'jid' => 'stuck' }))
      end

      expect(described_class.reconcile(Cogworker.identity, [raw])).to be_empty
      expect(in_progress).to eq([raw])
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

      expect(described_class.recover_orphans(scan: true)).to eq(1)

      expect(queue_jids).to eq(['orphan'])
      expect(in_progress('live-host:2:def').size).to eq(1)
      expect(in_progress.size).to eq(1)
      expect(log.string).to include('requeued 1 job(s) left in progress by dead process dead-host:1:abc')
    end

    it 'without scan, only looks at identities registered in the in-progress set — and forgets them once emptied' do
      expect(described_class.recover_orphans).to eq(0) # nothing registered: no keyspace SCAN

      Cogworker.config.redis { |c| c.sadd?('cogworker:inprogress_identities', 'dead-host:1:abc') }
      expect(described_class.recover_orphans).to eq(1)
      expect(Cogworker.config.redis { |c| c.smembers('cogworker:inprogress_identities') }).to be_empty
    end

    it 'is registered for by every beat of a reliable-fetch process, with its last beat time', :reliable_fetch do
      Cogworker::Heartbeat.new(Cogworker::Manager.new).send(:beat)

      expect(Cogworker.config.redis { |c| c.smembers('cogworker:inprogress_identities') }).to eq([Cogworker.identity])
      stamp = Cogworker.config.redis { |c| c.hget('cogworker:last_beat', Cogworker.identity) }.to_f
      expect(stamp).to be_within(5).of(Cogworker.config.redis { |c| c.time.first })
    end

    describe 'orphan_threshold' do
      def record_last_beat(seconds_ago)
        Cogworker.config.redis do |c|
          c.hset('cogworker:last_beat', 'dead-host:1:abc', c.time.first - seconds_ago)
          c.sadd?('cogworker:inprogress_identities', 'dead-host:1:abc')
        end
      end

      it 'leaves a process alone whose presence key expired but whose last beat is within the threshold — ' \
         'it may just have been unable to beat for a while, and requeueing would run its jobs twice' do
        record_last_beat(120)

        expect(described_class.recover_orphans).to eq(0)
        expect(queue_jids).to be_empty
      end

      it 'recovers it once its last beat is older than the threshold, and forgets its stamp' do
        record_last_beat(301)
        allow(Cogworker).to receive(:logger).and_return(Cogworker::Logging.default_logger(StringIO.new))

        expect(described_class.recover_orphans).to eq(1)
        expect(Cogworker.config.redis { |c| c.hget('cogworker:last_beat', 'dead-host:1:abc') }).to be_nil
      end

      it "never forgets a live process's registration or last beat while checking it" do
        record_last_beat(10)

        described_class.recover_orphans

        expect(Cogworker.config.redis { |c| c.hget('cogworker:last_beat', 'dead-host:1:abc') }).not_to be_nil
        expect(Cogworker.config.redis { |c| c.smembers('cogworker:inprogress_identities') }).to include('dead-host:1:abc')
      end

      it 'follows a configured threshold' do
        Cogworker.config.orphan_threshold = 60
        record_last_beat(90)
        allow(Cogworker).to receive(:logger).and_return(Cogworker::Logging.default_logger(StringIO.new))

        expect(described_class.recover_orphans).to eq(1)
      end
    end
  end

  describe 'Manager integration' do
    after { @manager&.stop!(timeout: 1) }

    it 'is the default fetch, and leaves nothing in progress once jobs have run', :reliable_fetch do
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

    it "doesn't touch Redis just to build a Manager — the fetch mode is resolved on first use" do
      expect(described_class).not_to receive(:supported?)
      Cogworker::Manager.new
    end

    it 'falls back to BasicFetch at runtime when LMOVE turns out unsupported, and still runs the job' do
      allow(described_class).to receive(:supported?).and_return(true)
      unsupported = Redis::CommandError.new('ERR Error running script (call to f_x): @user_script:4: ' \
                                            'Unknown Redis command called from Lua script')
      allow_any_instance_of(Redis).to receive(:evalsha).and_wrap_original do |original, sha, **kw|
        raise Redis::CommandError, 'NOSCRIPT No matching script' if sha == described_class::FETCH_SCRIPT_SHA

        original.call(sha, **kw)
      end
      allow_any_instance_of(Redis).to receive(:eval).and_wrap_original do |original, script, **kw|
        script == described_class::FETCH_SCRIPT ? raise(unsupported) : original.call(script, **kw)
      end
      allow_any_instance_of(Redis).to receive(:blmove).and_raise(Redis::CommandError, "ERR unknown command 'BLMOVE'")
      log = StringIO.new
      allow(Cogworker).to receive(:logger).and_return(Cogworker::Logging.default_logger(log))
      done = Queue.new
      stub_const('FallbackJob', Class.new { include Cogworker::Worker })
      FallbackJob.define_method(:perform) { done << :ok }
      FallbackJob.perform_async

      @manager = Cogworker::Manager.new
      @manager.start!

      expect(wait_for { done.pop(true) rescue nil }).to eq(:ok) # rubocop:disable Style/RescueModifier
      expect(@manager.fetch_class).to eq(Cogworker::BasicFetch)
      expect(log.string.scan("isn't supported by this Redis").size).to eq(1)
    end

    it "doesn't guess support while Redis is unreachable — it raises, so the choice is made again later" do
      allow_any_instance_of(Redis).to receive(:info).and_raise(Redis::CannotConnectError, 'down')

      expect { described_class.supported? }.to raise_error(Redis::CannotConnectError)
      manager = Cogworker::Manager.new
      expect { manager.fetch_class }.to raise_error(Redis::CannotConnectError)
      allow_any_instance_of(Redis).to receive(:info).and_call_original
      expect(manager.fetch_class).to eq(described_class.supported? ? described_class : Cogworker::BasicFetch)
    end

    it "reports support from the server's real version" do
      version = Cogworker.config.redis { |c| c.info('server')['redis_version'] }
      expect(described_class.supported?).to eq(Gem::Version.new(version) >= described_class::MIN_REDIS_VERSION)
    end

    it 'on a Redis without LMOVE, falls back at runtime when the boot-time check got it wrong', :old_redis do
      allow(described_class).to receive(:supported?).and_return(true) # e.g. Redis was unreachable at boot
      done = Queue.new
      stub_const('OldRedisRuntimeJob', Class.new { include Cogworker::Worker })
      OldRedisRuntimeJob.define_method(:perform) { done << :ok }
      OldRedisRuntimeJob.perform_async
      log = StringIO.new
      allow(Cogworker).to receive(:logger).and_return(Cogworker::Logging.default_logger(log))

      @manager = Cogworker::Manager.new
      @manager.start!

      expect(wait_for { done.pop(true) rescue nil }).to eq(:ok) # rubocop:disable Style/RescueModifier
      expect(@manager.fetch_class).to eq(Cogworker::BasicFetch)
      expect(log.string).to include("isn't supported by this Redis")
    end

    it 'on a Redis without LMOVE, still runs jobs with fetch: :reliable — via BasicFetch', :old_redis do
      done = Queue.new
      stub_const('OldRedisJob', Class.new { include Cogworker::Worker })
      OldRedisJob.define_method(:perform) { done << :ok }
      OldRedisJob.perform_async
      allow(Cogworker).to receive(:logger).and_return(Cogworker::Logging.default_logger(StringIO.new))

      @manager = Cogworker::Manager.new
      @manager.start!

      expect(wait_for { done.pop(true) rescue nil }).to eq(:ok) # rubocop:disable Style/RescueModifier
      expect(@manager.fetch_class).to eq(Cogworker::BasicFetch)
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
  it "re-takes an until_executed periodic run's lapsed lock as it requeues it" do
    Cogworker.config.redis do |c|
      c.hset("cogworker:workers:#{Cogworker.identity}", 't1',
             JSON.generate('queue' => 'default', 'payload' => { 'jid' => 'run2', 'queue' => 'default',
                                                                'periodic_pjid' => 'pj2',
                                                                'periodic_until_executed' => true }))
    end

    described_class.requeue_in_progress(Cogworker.identity)

    expect(Cogworker.config.redis { |c| c.get('periodic:running:pj2') }).to eq('run2')
  end

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
RSpec.describe 'ReliableFetch surviving a killed process (end-to-end, real OS process)', :reliable_fetch do
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

    # What time does on its own: the presence key expires a minute later,
    # and orphan_threshold (default 5 min) passes since the last beat.
    Cogworker.config.redis do |c|
      c.del("cogworker:process:#{identity}")
      c.hset('cogworker:last_beat', identity, c.time.first - Cogworker.config.orphan_threshold - 1)
    end
    Cogworker::ReliableFetch.recover_orphans

    requeued = Cogworker.config.redis { |c| c.lrange('cogworker:queue:default', 0, -1) }
    expect(requeued.map { |raw| JSON.parse(raw)['jid'] }).to eq([jid])
  end
end
