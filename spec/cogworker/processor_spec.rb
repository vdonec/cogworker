# frozen_string_literal: true

require 'spec_helper'
require 'json'
require 'stringio'

RSpec.describe 'Manager + Processor end-to-end execution' do
  after do
    @manager&.stop!(timeout: 2)
  end

  it 'runs a pushed job through the full server middleware chain and updates stats' do
    executed = Queue.new
    trace = []

    tagging_middleware = Class.new do
      define_method(:call) do |_worker, job, _queue, &block|
        trace << job['class']
        block.call
      end
    end
    Cogworker.config.server_middleware { |chain| chain.add(tagging_middleware) }

    stub_const('EchoJob', Class.new do
      include Cogworker::Worker
    end)
    EchoJob.define_method(:perform) { |*args| executed << args }

    EchoJob.perform_async(1, 'two')

    @manager = Cogworker::Manager.new
    @manager.start!

    result = wait_for do
      executed.pop(true)
    rescue StandardError
      nil
    end
    expect(result).to eq([1, 'two'])
    expect(trace).to eq(['EchoJob'])

    expect(Cogworker::Stats.new.processed).to eq(1)
    expect(Cogworker::Stats.new.failed).to eq(0)

    series = Cogworker::Throughput.series(hours: 1)
    expect(series.first['processed']).to eq(1)
    expect(series.first['failed']).to eq(0)
  end

  it 'routes a failing job with retry: false straight to the dead set' do
    stub_const('BoomJob', Class.new do
      include Cogworker::Worker
      cogworker_options retry: false

      def perform(*)
        raise 'kaboom'
      end
    end)

    jid = BoomJob.perform_async

    @manager = Cogworker::Manager.new
    @manager.start!

    wait_for { Cogworker::Stats.new.dead_size == 1 }
    expect(Cogworker::Stats.new.retry_size).to eq(0)
    expect(Cogworker::Stats.new.failed).to eq(1)

    attempts = Cogworker::Attempts.for(jid)
    expect(attempts.size).to eq(1)
    expect(attempts.first).to include('attempt' => 1, 'outcome' => 'dead', 'error_class' => 'RuntimeError',
                                      'error_message' => 'kaboom')

    series = Cogworker::Throughput.series(hours: 1)
    expect(series.first['failed']).to eq(1)
    expect(series.first['processed']).to eq(0)
  end

  it 'routes a failing job with retries remaining to the retry set with error info' do
    stub_const('FlakyJob', Class.new do
      include Cogworker::Worker
      cogworker_options retry: 3

      def perform(*)
        raise ArgumentError, 'nope'
      end
    end)

    FlakyJob.perform_async

    @manager = Cogworker::Manager.new
    @manager.start!

    wait_for { Cogworker::Stats.new.retry_size == 1 }
    raw = Cogworker.config.redis { |c| c.zrange('cogworker:retry', 0, 0) }.first
    job = JSON.parse(raw)
    expect(job['error_class']).to eq('ArgumentError')
    expect(job['retry_count']).to eq(1)

    attempts = Cogworker::Attempts.for(job['jid'])
    expect(attempts.size).to eq(1)
    expect(attempts.first).to include('attempt' => 1, 'outcome' => 'retrying', 'error_class' => 'ArgumentError',
                                      'error_message' => 'nope')
  end

  it 'runs a job whose class was never defined through the same middleware chain as any other ' \
     'failure — History/Status must see it too, not just retry/dead routing' do
    Cogworker::History.configure_server_middleware(Cogworker.config, max_entries: 100)
    Cogworker::Status.configure_server_middleware(Cogworker.config, expiration: 60)

    # Pushed directly (not via `.perform_async`, which needs a real class to
    # call it on) — this is exactly the shape a `retry`/`retry_now` button
    # click produces for an entry whose class no longer exists.
    raw = JSON.generate('jid' => 'ghostjid', 'class' => 'TotallyUndefinedGhostJob', 'args' => [],
                        'queue' => 'default', 'retry' => 0)
    Cogworker.config.redis do |c|
      c.sadd?('cogworker:queues', 'default')
      c.lpush('cogworker:queue:default', raw)
    end

    @manager = Cogworker::Manager.new
    @manager.start!

    wait_for { Cogworker::Stats.new.dead_size == 1 } # unaffected: still routes to dead as before

    entries, = Cogworker::History::Storage.page('failed', 1, 10)
    entry = entries.find { |e| e['jid'] == 'ghostjid' }
    expect(entry).not_to be_nil, 'expected the History entry for the unresolvable class to exist'
    expect(entry['error_class']).to eq('NameError')

    expect(Cogworker::Status.status('ghostjid')).to eq(:failed)
  end

  it "a job with retry: false (the literal boolean, not 0) doesn't crash Status middleware — " \
     "JobUtil.max_retries handles false/true/nil/Integer explicitly, never job['retry'].to_i " \
     'directly (FalseClass has no #to_i)' do
    Cogworker::Status.configure_server_middleware(Cogworker.config, expiration: 60)

    stub_const('BoomOnceJob', Class.new do
      include Cogworker::Worker
      cogworker_options retry: false

      def perform(*)
        raise 'kaboom'
      end
    end)

    BoomOnceJob.perform_async

    @manager = Cogworker::Manager.new
    @manager.start!

    wait_for { Cogworker::Stats.new.dead_size == 1 }
    jid = Cogworker.config.redis { |c| c.zrange('cogworker:dead', 0, 0) }.first
                   .then { |raw| JSON.parse(raw)['jid'] }
    expect(Cogworker::Status.status(jid)).to eq(:failed)
  end

  it 'registers and deregisters in-flight jobs in the WorkSet while running' do
    gate = Queue.new
    stub_const('SlowJob', Class.new do
      include Cogworker::Worker
      define_method(:perform) { gate.pop }
    end)

    SlowJob.perform_async

    @manager = Cogworker::Manager.new
    @manager.start!
    # WorkSet discovers in-flight jobs by first listing live processes from
    # ProcessSet, so a heartbeat beat has to exist for it to look under.
    Cogworker::Heartbeat.new(@manager).send(:beat)

    wait_for { Cogworker::WorkSet.new.size == 1 }
    work = Cogworker::WorkSet.new.to_a.first[2]
    expect(work.job['class']).to eq('SlowJob')
    expect(work.queue).to eq('default')

    gate << :go
    wait_for { Cogworker::WorkSet.new.size == 0 } # rubocop:disable Style/ZeroLengthPredicate -- WorkSet has no #empty? (Enumerable doesn't provide one)
  end

  it 'moves an unparseable payload to dead and keeps processing the next job on the same thread' do
    executed = Queue.new
    stub_const('AfterJunkJob', Class.new do
      include Cogworker::Worker
    end)
    AfterJunkJob.define_method(:perform) { executed << :ok }

    Cogworker.config.concurrency = 1
    Cogworker.config.redis { |c| c.lpush('cogworker:queue:default', '{not json') }
    AfterJunkJob.perform_async

    @manager = Cogworker::Manager.new
    @manager.start!

    expect(wait_for { executed.pop(true) rescue nil }).to eq(:ok) # rubocop:disable Style/RescueModifier
    dead = Cogworker.config.redis { |c| c.zrange('cogworker:dead', 0, -1) }.map { |raw| JSON.parse(raw) }
    expect(dead.size).to eq(1)
    expect(dead.first).to include('class' => '(unparseable)', 'queue' => 'default',
                                  'error_class' => 'JSON::ParserError', 'raw_payload' => '{not json')
    expect(Cogworker::Stats.new.failed).to eq(1)
  end

  it 'survives an error while fetching instead of the thread dying for good' do
    executed = Queue.new
    stub_const('AfterBlipJob', Class.new do
      include Cogworker::Worker
    end)
    AfterBlipJob.define_method(:perform) { executed << :ok }
    AfterBlipJob.perform_async

    Cogworker.config.concurrency = 1
    @manager = Cogworker::Manager.new
    fetcher_calls = 0
    original = @manager.fetch_class.instance_method(:retrieve_work)
    allow_any_instance_of(@manager.fetch_class).to receive(:retrieve_work) do |fetcher|
      (fetcher_calls += 1) == 1 ? raise(Redis::CannotConnectError, 'blip') : original.bind_call(fetcher)
    end
    @manager.start!

    expect(wait_for { executed.pop(true) rescue nil }).to eq(:ok) # rubocop:disable Style/RescueModifier
    expect(fetcher_calls).to be >= 2
  end

  describe 'acknowledging a finished job' do
    let(:processor) { Cogworker::Processor.new(Cogworker::Manager.new) }
    let(:fetcher) { processor.send(:fetcher) }
    let(:work) { Cogworker::BasicFetch::UnitOfWork.new('default', JSON.generate('jid' => 'ackjid')) }
    let(:log) { StringIO.new }

    before do
      allow(processor).to receive(:sleep)
      allow(Cogworker).to receive(:logger).and_return(Cogworker::Logging.default_logger(log))
    end

    it 'retries a failed ack' do
      calls = 0
      allow(fetcher).to receive(:acknowledge) { (calls += 1) < 3 ? raise(Redis::CannotConnectError, 'blip') : nil }

      processor.send(:acknowledge, work)

      expect(calls).to eq(3)
      expect(log.string).not_to include("couldn't acknowledge")
    end

    it 'logs the jid when every attempt fails, without raising' do
      allow(fetcher).to receive(:acknowledge).and_raise(Redis::CannotConnectError, 'blip')

      expect { processor.send(:acknowledge, work) }.not_to raise_error
      expect(log.string).to include("couldn't acknowledge finished job jid=ackjid after 3 attempts")
    end
  end

  it 'interrupts a job that ran (into retry, not its queue) when recording its failure blows up' do
    stub_const('BookkeepingJob', Class.new { include Cogworker::Worker })
    BookkeepingJob.define_method(:perform) { raise 'boom' }
    jid = BookkeepingJob.perform_async
    allow(Cogworker).to receive(:logger).and_return(Cogworker::Logging.default_logger(StringIO.new))

    manager = Cogworker::Manager.new
    processor = Cogworker::Processor.new(manager)
    allow(processor).to receive(:route_failure).and_raise(Redis::CannotConnectError, 'zadd failed')

    expect { processor.send(:process_one) }.to raise_error(Redis::CannotConnectError)

    expect(Cogworker.config.redis { |c| c.zcard('cogworker:retry') }).to eq(1)
    expect(queued_jobs).to be_empty
    expect(JSON.parse(Cogworker.config.redis { |c| c.zrange('cogworker:retry', 0, 0) }.first)['jid']).to eq(jid)
    expect(Cogworker.config.redis { |c| c.llen("cogworker:inprogress:#{Cogworker.identity}") }).to eq(0)
  end

  describe 'what happens to a job after it has run' do
    let(:manager) { Cogworker::Manager.new }
    let(:processor) { Cogworker::Processor.new(manager) }
    let(:log) { StringIO.new }

    before { allow(Cogworker).to receive(:logger).and_return(Cogworker::Logging.default_logger(log)) }

    def counts
      Cogworker.config.redis do |c|
        { retry: c.zcard('cogworker:retry'), dead: c.zcard('cogworker:dead'), queued: c.llen('cogworker:queue:default'),
          in_progress: c.llen("cogworker:inprogress:#{Cogworker.identity}") }
      end
    end

    def define_job(name, &perform)
      stub_const(name, Class.new { include Cogworker::Worker })
      Object.const_get(name).define_method(:perform, &perform)
    end

    it 'records a failure whose message is not valid UTF-8 (it used to loop forever, re-running every second)' do
      runs = 0
      define_job('PoisonJob') { |*| (runs += 1) && raise("bad \xff".b) }
      PoisonJob.perform_async

      processor.send(:process_one)

      expect(runs).to eq(1)
      expect(counts).to eq(retry: 1, dead: 0, queued: 0, in_progress: 0)
      retried = JSON.parse(Cogworker.config.redis { |c| c.zrange('cogworker:retry', 0, 0) }.first)
      expect(retried['error_message']).to eq("bad \uFFFD")
    end

    it 'never re-runs a job that succeeded, when deregistering it or counting it fails afterwards' do
      runs = 0
      define_job('DoneJob') { |*| runs += 1 }
      DoneJob.perform_async
      allow(processor).to receive(:deregister_from_workers).and_raise(Redis::CannotConnectError, 'hdel failed')
      allow(Cogworker::Throughput).to receive(:record).and_raise(Redis::CannotConnectError, 'incr failed')

      processor.send(:process_one)

      expect(runs).to eq(1)
      expect(counts).to eq(retry: 0, dead: 0, queued: 0, in_progress: 0)
      expect(log.string).to include('deregister failed (ignored)', 'stats failed (ignored)')
    end

    it 'leaves a failure that made it into retry there, even if what comes after (attempts log) fails' do
      define_job('FlakyAfterJob') { |*| raise 'boom' }
      FlakyAfterJob.perform_async
      allow(Cogworker::Attempts).to receive(:record).and_raise(Redis::CannotConnectError, 'rpush failed')

      processor.send(:process_one)

      expect(counts).to eq(retry: 1, dead: 0, queued: 0, in_progress: 0)
    end

    it "interrupts a job whose failure can't be recorded into retry, with a delay and a count — never the queue" do
      define_job('UnrecordableJob') { |*| raise 'boom' }
      nan = Class.new do
        def call(_worker, job, _queue)
          job['poisoned'] = Float::NAN # makes JSON.generate(job) raise, every time
          yield
        end
      end
      Cogworker.config.server_middleware { |chain| chain.add(nan) }
      UnrecordableJob.perform_async

      processor.send(:process_one)

      expect(counts).to eq(retry: 1, dead: 0, queued: 0, in_progress: 0)
      raw, score = Cogworker.config.redis { |c| c.zrange('cogworker:retry', 0, 0, withscores: true) }.first
      job = JSON.parse(raw)
      expect(job).to include('interrupted_count' => 1, 'retry_count' => 1, 'error_class' => 'RuntimeError')
      expect(job).not_to have_key('poisoned')
      expect(score).to be_within(5).of(Time.now.to_f + Cogworker::Processor::INTERRUPT_DELAY)
    end

    it 'sends a job to dead once it has been interrupted more than MAX_INTERRUPTS times' do
      raw = JSON.generate('jid' => 'int', 'class' => 'X', 'queue' => 'default', 'args' => [],
                          'interrupted_count' => Cogworker::Processor::MAX_INTERRUPTS)
      work = Cogworker::BasicFetch::UnitOfWork.new('default', raw)
      Cogworker.config.redis { |c| c.lpush("cogworker:inprogress:#{Cogworker.identity}", raw) } # as fetched

      processor.send(:interrupt, work, { 'retry_count' => 4 }, RuntimeError.new('boom'))

      expect(counts).to include(retry: 0, dead: 1)
    end
  end

  describe 'interrupting (recording the failure itself failed)' do
    let(:processor) { Cogworker::Processor.new(Cogworker::Manager.new) }

    before { allow(Cogworker).to receive(:logger).and_return(Cogworker::Logging.default_logger(StringIO.new)) }

    # `attempt`: the number of the attempt whose failure couldn't be recorded
    # (the fetched payload carries the previous attempts' count).
    def interrupt(job_fields, attempt)
      raw = JSON.generate({ 'jid' => 'i1', 'class' => 'X', 'queue' => 'default', 'args' => [],
                            'retry_count' => attempt - 1 }.merge(job_fields))
      retry_count = attempt
      Cogworker.config.redis { |c| c.lpush("cogworker:inprogress:#{Cogworker.identity}", raw) }
      job = JSON.parse(raw).merge('retry_count' => retry_count)
      processor.send(:interrupt, Cogworker::BasicFetch::UnitOfWork.new('default', raw), job, RuntimeError.new('boom'))
      Cogworker.config.redis { |c| [c.zcard('cogworker:retry'), c.zcard('cogworker:dead')] }
    end

    it 'sends a job with retry: false straight to dead — no extra attempt it was never allowed' do
      expect(interrupt({ 'retry' => false }, 1)).to eq([0, 1])
    end

    it 'sends a job whose last retry was this one straight to dead' do
      expect(interrupt({ 'retry' => 2 }, 3)).to eq([0, 1])
    end

    it 'extends a unique job\'s lock over the interruption delay' do
      fields = { 'unique' => 'until_executed', 'retry' => 3 }
      digest = Cogworker::UniqueJobs.digest(JSON.parse(JSON.generate({ 'class' => 'X', 'queue' => 'default',
                                                                       'args' => [] })))
      Cogworker.config.redis { |c| c.set("cogworker:unique:#{digest}", 'i1', ex: 5) }

      expect(interrupt(fields, 1)).to eq([1, 0])
      expect(Cogworker.config.redis { |c| c.ttl("cogworker:unique:#{digest}") }).to be > Cogworker::Processor::INTERRUPT_DELAY
    end
  end

  it 'records a failure whose exception raises from #message, instead of re-running it every second' do
    broken = Class.new(StandardError) { def message = raise('no message for you') }
    stub_const('BrokenMessageError', broken)
    stub_const('BrokenMessageJob', Class.new { include Cogworker::Worker })
    runs = 0
    BrokenMessageJob.define_method(:perform) { |*| (runs += 1) && raise(BrokenMessageError) }
    BrokenMessageJob.perform_async
    allow(Cogworker).to receive(:logger).and_return(Cogworker::Logging.default_logger(StringIO.new))

    Cogworker::Processor.new(Cogworker::Manager.new).send(:process_one)

    expect(runs).to eq(1)
    retried = JSON.parse(Cogworker.config.redis { |c| c.zrange('cogworker:retry', 0, 0) }.first)
    expect(retried['error_message']).to eq('#<BrokenMessageError>')
  end

  it "doesn't re-run, on shutdown, a job that finished but whose ack failed", :reliable_fetch do
    manager = Cogworker::Manager.new
    raw = JSON.generate('jid' => 'done1', 'queue' => 'default')
    Cogworker.config.redis { |c| c.lpush("cogworker:inprogress:#{Cogworker.identity}", raw) }
    manager.settle_later(raw, :ack)

    manager.stop!(timeout: 0)

    expect(queued_jobs).to be_empty
    expect(Cogworker.config.redis { |c| c.llen("cogworker:inprogress:#{Cogworker.identity}") }).to eq(0)
  end

  describe 'an unexpected exception after the job ran' do
    let(:processor) { Cogworker::Processor.new(Cogworker::Manager.new) }

    before { allow(Cogworker).to receive(:logger).and_return(Cogworker::Logging.default_logger(StringIO.new)) }

    def counts
      Cogworker.config.redis do |c|
        [c.zcard('cogworker:retry'), c.zcard('cogworker:dead'), c.llen('cogworker:queue:default'),
         c.llen("cogworker:inprogress:#{Cogworker.identity}")]
      end
    end

    it 'never re-queues a failed job — with retry: false, it goes to dead' do
      stub_const('NoRetryJob', Class.new { include Cogworker::Worker })
      runs = 0
      NoRetryJob.define_method(:perform) { |*| (runs += 1) && raise('boom') }
      Cogworker::Client.push('class' => 'NoRetryJob', 'args' => [], 'retry' => false)
      allow(processor).to receive(:route_failure).and_raise(NoMethodError, 'bug in bookkeeping')

      expect { processor.send(:process_one) }.to raise_error(NoMethodError)

      expect(runs).to eq(1)
      expect(counts).to eq([0, 1, 0, 0])
    end

    it 'acknowledges a job that succeeded, rather than re-queueing it' do
      stub_const('OkJob', Class.new { include Cogworker::Worker })
      OkJob.define_method(:perform) { |*| nil }
      OkJob.perform_async
      allow(processor).to receive(:finish_success).and_raise(NoMethodError, 'bug in bookkeeping')

      expect { processor.send(:process_one) }.to raise_error(NoMethodError)

      expect(counts).to eq([0, 0, 0, 0])
    end

    it 'still runs a job whose registration in cogworker:workers fails (the key holding the wrong type)' do
      stub_const('RegJob', Class.new { include Cogworker::Worker })
      runs = 0
      RegJob.define_method(:perform) { |*| runs += 1 }
      RegJob.perform_async
      Cogworker.config.redis { |c| c.set("cogworker:workers:#{Cogworker.identity}", 'not a hash') }

      processor.send(:process_one)

      expect(runs).to eq(1)
      expect(counts).to eq([0, 0, 0, 0])
    end
  end

  it 'never re-runs a retry: false job whose failure could not be filed anywhere — reconcile keeps filing it',
     :reliable_fetch do
    manager = Cogworker::Manager.new
    processor = Cogworker::Processor.new(manager)
    allow(Cogworker).to receive(:logger).and_return(Cogworker::Logging.default_logger(StringIO.new))
    stub_const('DoomedJob', Class.new { include Cogworker::Worker })
    runs = 0
    DoomedJob.define_method(:perform) { |*| (runs += 1) && raise('boom') }
    Cogworker::Client.push('class' => 'DoomedJob', 'args' => [], 'retry' => false)
    Cogworker.config.redis { |c| c.set('cogworker:dead', 'not a zset') } # every write to dead fails

    processor.send(:process_one)
    expect(manager.pending_settlements.size).to eq(1)

    reconcile = lambda do |strays|
      Cogworker::ReliableFetch.reconcile(Cogworker.identity, strays, running: manager.running_jobs,
                                                                     pending: manager.pending_settlements) do |raw|
        manager.settled(raw)
      end
    end
    strays = []
    2.times { strays = reconcile.call(strays) }
    expect(queued_jobs).to be_empty # not requeued as a stray

    Cogworker.config.redis { |c| c.del('cogworker:dead') } # Redis is fine again
    reconcile.call(strays)

    expect(runs).to eq(1)
    expect(Cogworker.config.redis { |c| c.zcard('cogworker:dead') }).to eq(1)
    expect(manager.pending_settlements).to be_empty
    expect(Cogworker.config.redis { |c| c.llen("cogworker:inprogress:#{Cogworker.identity}") }).to eq(0)
  end

  it 'keeps a payload marked running until every concurrent copy of it has finished' do
    manager = Cogworker::Manager.new
    manager.job_started('same')
    manager.job_started('same')
    manager.job_finished('same')

    expect(manager.running_jobs).to eq(['same'])
    manager.job_finished('same')
    expect(manager.running_jobs).to be_empty
  end

  it 'hands an unfileable failure over to cogworker:unsettled on shutdown — never requeues it — ' \
     "and it's filed once possible",
     :reliable_fetch do
    manager = Cogworker::Manager.new
    raw = JSON.generate('jid' => 'pay1', 'class' => 'PaymentJob', 'queue' => 'default', 'args' => [], 'retry' => false)
    Cogworker.config.redis do |c|
      c.lpush("cogworker:inprogress:#{Cogworker.identity}", raw)
      c.set('cogworker:dead', 'not a zset')
    end
    manager.settle_later(raw, ['cogworker:dead', 1.0, JSON.generate('jid' => 'pay1', 'error_class' => 'X')])
    allow(Cogworker).to receive(:logger).and_return(Cogworker::Logging.default_logger(StringIO.new))

    manager.stop!(timeout: 0)

    expect(queued_jobs).to be_empty
    expect(Cogworker.config.redis { |c| c.llen("cogworker:inprogress:#{Cogworker.identity}") }).to eq(0)
    expect(Cogworker.config.redis { |c| c.llen('cogworker:unsettled') }).to eq(1)

    Cogworker.config.redis { |c| c.del('cogworker:dead') }
    Cogworker::ReliableFetch.recover_orphans

    expect(Cogworker.config.redis { |c| [c.zcard('cogworker:dead'), c.llen('cogworker:unsettled')] }).to eq([1, 0])
  end

  it 'remembers a job for dead when interrupt itself blows up before writing anything — never a stray to re-run',
     :reliable_fetch do
    manager = Cogworker::Manager.new
    processor = Cogworker::Processor.new(manager)
    allow(Cogworker).to receive(:logger).and_return(Cogworker::Logging.default_logger(StringIO.new))
    raw = JSON.generate('jid' => 'odd', 'class' => 'X', 'queue' => 'default', 'args' => [])
    allow(Cogworker::JobUtil).to receive(:max_retries).and_raise(NoMethodError, 'unexpected')

    processor.send(:interrupt, Cogworker::BasicFetch::UnitOfWork.new('default', raw), {}, RuntimeError.new('boom'))

    set, _score, entry = manager.pending_settlements.fetch(raw)
    expect(set).to eq('cogworker:dead')
    expect(JSON.parse(entry)).to include('jid' => 'odd', 'error_class' => 'RuntimeError')
  end

  it 'releases the locks of a job that goes to dead by way of interrupt with retries still left', :reliable_fetch do
    manager = Cogworker::Manager.new
    processor = Cogworker::Processor.new(manager)
    allow(Cogworker).to receive(:logger).and_return(Cogworker::Logging.default_logger(StringIO.new))
    raw = JSON.generate('jid' => 'lk', 'class' => 'X', 'queue' => 'default', 'args' => [], 'retry' => 5,
                        'unique' => 'until_executed', 'periodic_pjid' => 'pjl',
                        'interrupted_count' => Cogworker::Processor::MAX_INTERRUPTS)
    digest = Cogworker::UniqueJobs.digest(JSON.parse(raw))
    Cogworker.config.redis do |c|
      c.lpush("cogworker:inprogress:#{Cogworker.identity}", raw)
      c.set("cogworker:unique:#{digest}", 'lk')
      c.set('periodic:running:pjl', 'lk')
    end

    processor.send(:interrupt, Cogworker::BasicFetch::UnitOfWork.new('default', raw), {}, RuntimeError.new('boom'))

    expect(Cogworker.config.redis { |c| c.zcard('cogworker:dead') }).to eq(1)
    expect(Cogworker.config.redis { |c| [c.get("cogworker:unique:#{digest}"), c.get('periodic:running:pjl')] })
      .to eq([nil, nil])
  end
end

RSpec.describe 'Processor with cogworker_retry_in / cogworker_retries_exhausted / death_handlers' do
  let(:processor) { Cogworker::Processor.new(Cogworker::Manager.new) }
  let(:log) { StringIO.new }
  let(:deaths) { [] }

  before do
    allow(Cogworker).to receive(:logger).and_return(Cogworker::Logging.default_logger(log))
    deaths = self.deaths
    Cogworker.config.death_handlers << ->(job, e) { deaths << [:handler, job['jid'], e.class, e.message] }
  end

  def define_job(name, options = {}, &perform)
    stub_const(name, Class.new { include Cogworker::Worker })
    klass = Object.const_get(name)
    klass.cogworker_options(options)
    klass.define_method(:perform, &perform)
    klass
  end

  def entries(set)
    Cogworker.config.redis { |c| c.zrange("cogworker:#{set}", 0, -1, withscores: true) }
             .map { |raw, score| [JSON.parse(raw), score] }
  end

  def counts
    Cogworker.config.redis do |c|
      { retry: c.zcard('cogworker:retry'), dead: c.zcard('cogworker:dead'), queued: c.llen('cogworker:queue:default'),
        in_progress: c.llen("cogworker:inprogress:#{Cogworker.identity}") }
    end
  end

  def queued_digest
    Cogworker::UniqueJobs.digest(JSON.parse(Cogworker.config.redis { |c| c.lindex('cogworker:queue:default', 0) }))
  end

  # Puts the job waiting in retry straight back on its queue, the way
  # Scheduled does once it's due.
  def graduate
    Cogworker.config.redis do |c|
      raw = c.zrange('cogworker:retry', 0, 0).first
      Cogworker::JobUtil.claim_and_requeue(c, 'cogworker:retry', raw)
    end
  end

  it "uses the hook's number as the delay, without jitter, passing count 0, 1, 2 on the first three failures" do
    seen = []
    define_job('TimedJob', retry: 5) { |*| raise 'boom' }
    TimedJob.cogworker_retry_in do |count, exception, job|
      seen << [count, exception.message, job['jid']]
      600 * (2**count)
    end
    jid = TimedJob.perform_async

    3.times do |i|
      graduate unless i.zero?
      processor.send(:process_one)
      (job, score), = entries(:retry)
      expect(score).to be_within(2).of(Time.now.to_f + (600 * (2**i)))
      expect(job['retry_count']).to eq(i + 1)
      expect(job).not_to have_key('failure_outcome')
    end
    expect(seen).to eq([[0, 'boom', jid], [1, 'boom', jid], [2, 'boom', jid]])
    expect(Cogworker::Attempts.for(jid).map { |a| a['outcome'] }).to eq(%w[retrying retrying retrying])
  end

  it 'accepts 0 (due on the next poll) and a Float' do
    define_job('ZeroJob') { |*| raise 'boom' }
    ZeroJob.cogworker_retry_in { |count| count.zero? ? 0 : 1.5 }
    ZeroJob.perform_async

    processor.send(:process_one)
    expect(entries(:retry).first.last).to be_within(1).of(Time.now.to_f)
    graduate
    processor.send(:process_one)
    expect(entries(:retry).first.last).to be_within(1).of(Time.now.to_f + 1.5)
  end

  [nil, -5, 'soon', Float::NAN, Float::INFINITY, :later].each do |value|
    it "falls back to the default backoff when the hook returns #{value.inspect}" do
      define_job('OddJob') { |*| raise 'boom' }
      OddJob.cogworker_retry_in { |*| value }
      OddJob.perform_async

      processor.send(:process_one)

      expect(counts).to eq(retry: 1, dead: 0, queued: 0, in_progress: 0)
      job, score = entries(:retry).first
      expect(score - Time.now.to_f).to be_between(14, 75) # 1**4 + 15 + rand(30) * 2
      expect(job).not_to have_key('interrupted_count')
      expect(log.string).to include('cogworker_retry_in of OddJob returned') unless value.nil?
    end
  end

  it 'falls back to the default backoff (logged, never an interrupt) when the hook raises' do
    define_job('RaisingHookJob') { |*| raise 'boom' }
    RaisingHookJob.cogworker_retry_in { |*| raise 'hook bug' }
    RaisingHookJob.perform_async

    processor.send(:process_one)

    expect(counts).to eq(retry: 1, dead: 0, queued: 0, in_progress: 0)
    expect(entries(:retry).first.first).not_to have_key('interrupted_count')
    expect(log.string).to include('cogworker_retry_in of RaisingHookJob raised', 'hook bug')
  end

  it 'kills a job with retries left on :kill — straight to dead, with the death hooks' do
    define_job('KilledJob', retry: 10) { |*| raise ArgumentError, 'permanent' }
    deaths = self.deaths
    KilledJob.cogworker_retry_in { |_count, e| :kill if e.is_a?(ArgumentError) }
    KilledJob.cogworker_retries_exhausted { |job, e| deaths << [:class, job['jid'], e.class, e.message] }
    jid = KilledJob.perform_async

    processor.send(:process_one)

    expect(counts).to eq(retry: 0, dead: 1, queued: 0, in_progress: 0)
    expect(entries(:dead).first.first).to include('retry_count' => 1, 'error_class' => 'ArgumentError')
    expect(entries(:dead).first.first).not_to have_key('failure_outcome')
    expect(deaths).to eq([[:class, jid, ArgumentError, 'permanent'], [:handler, jid, ArgumentError, 'permanent']])
    expect(Cogworker::Attempts.for(jid).map { |a| a['outcome'] }).to eq(%w[killed])
  end

  it 'discards on :discard — neither retry nor dead, no death hooks, locks released, counted as failed' do
    define_job('DiscardedJob', retry: 10, unique: :until_executed) { |*| raise 'stale' }
    DiscardedJob.cogworker_retry_in { |*| :discard }
    DiscardedJob.cogworker_retries_exhausted { |*| deaths << :class }
    jid = DiscardedJob.perform_async
    digest = queued_digest
    expect(Cogworker.config.redis { |c| c.get("cogworker:unique:#{digest}") }).to eq(jid)

    processor.send(:process_one)

    expect(counts).to eq(retry: 0, dead: 0, queued: 0, in_progress: 0)
    expect(deaths).to be_empty
    expect(Cogworker.config.redis { |c| c.get("cogworker:unique:#{digest}") }).to be_nil
    expect(Cogworker::Stats.new.failed).to eq(1)
    expect(Cogworker::Attempts.for(jid).map { |a| a['outcome'] }).to eq(%w[discarded])
  end

  it 'runs the class hook, then the death handlers, exactly once, with the entry already in dead — retries used up' do
    define_job('ExhaustedJob', retry: 1) { |*| raise 'boom' }
    seen_dead = []
    ExhaustedJob.cogworker_retries_exhausted do |job, e|
      seen_dead << Cogworker.config.redis { |c| c.zcard('cogworker:dead') }
      deaths << [:class, job['jid'], e.class, e.message]
      job['retry_count']
    end
    retry_in_calls = 0
    ExhaustedJob.cogworker_retry_in { |*| (retry_in_calls += 1) && 1 }
    jid = ExhaustedJob.perform_async

    processor.send(:process_one)
    expect(deaths).to be_empty
    graduate
    processor.send(:process_one)

    expect(counts).to eq(retry: 0, dead: 1, queued: 0, in_progress: 0)
    expect(retry_in_calls).to eq(1) # not asked about the last failure: there's no retry to time
    expect(seen_dead).to eq([1])
    expect(deaths).to eq([[:class, jid, RuntimeError, 'boom'], [:handler, jid, RuntimeError, 'boom']])
  end

  it 'runs the death hooks for retry: false on the first failure, without asking retry_in' do
    define_job('OneShotJob', retry: false) { |*| raise 'boom' }
    OneShotJob.cogworker_retry_in { |*| raise 'must not be called' }
    jid = OneShotJob.perform_async

    processor.send(:process_one)

    expect(counts).to include(dead: 1, retry: 0)
    expect(deaths).to eq([[:handler, jid, RuntimeError, 'boom']])
    expect(log.string).not_to include('must not be called')
  end

  it "hands the hooks the job as stored in dead, and a hook's changes don't reach that entry" do
    define_job('StoredJob', retry: false) { |*| raise 'boom' }
    received = nil
    StoredJob.cogworker_retries_exhausted do |job, _e|
      received = job.dup
      job['error_message'] = 'tampered'
    end
    StoredJob.perform_async

    processor.send(:process_one)

    stored = entries(:dead).first.first
    expect(received).to eq(stored)
    expect(stored).to include('error_class' => 'RuntimeError', 'error_message' => 'boom', 'retry_count' => 1)
    expect(stored['failed_at']).to be_a(Float)
  end

  it "doesn't let a raising death hook break the ack, the other handlers or the lock release" do
    define_job('HookBreaksJob', retry: false, unique: :until_executed) { |*| raise 'boom' }
    HookBreaksJob.cogworker_retries_exhausted { |*| raise 'hook broke' }
    Cogworker.config.death_handlers.unshift(->(*) { raise 'handler broke' })
    jid = HookBreaksJob.perform_async
    digest = queued_digest

    processor.send(:process_one)

    expect(counts).to eq(retry: 0, dead: 1, queued: 0, in_progress: 0)
    expect(deaths).to eq([[:handler, jid, RuntimeError, 'boom']])
    expect(Cogworker.config.redis { |c| c.get("cogworker:unique:#{digest}") }).to be_nil
    expect(log.string).to include('hook broke', 'handler broke')
  end

  describe 'when the retry/dead write itself fails' do
    let(:poison) do
      Class.new do
        def call(_worker, job, _queue)
          job['poisoned'] = Float::NAN # JSON.generate(job) raises, every time
          yield
        end
      end
    end

    before { Cogworker.config.server_middleware { |chain| chain.add(poison) } }

    it 'runs the death hooks once when the interrupt files the job in dead' do
      define_job('InterruptedDeadJob', retry: false) { |*| raise 'boom' }
      jid = InterruptedDeadJob.perform_async

      processor.send(:process_one)

      expect(counts).to include(dead: 1, retry: 0, in_progress: 0)
      expect(deaths).to eq([[:handler, jid, RuntimeError, 'boom']])
    end

    it "runs none while the job couldn't be filed anywhere yet" do
      define_job('UnfiledJob', retry: false) { |*| raise 'boom' }
      UnfiledJob.perform_async
      allow(processor.send(:fetcher)).to receive(:interrupt).and_raise(Redis::CannotConnectError, 'gone')

      processor.send(:process_one)

      expect(counts).to include(dead: 0, retry: 0)
      expect(deaths).to be_empty
    end

    it 'still honors :kill, filing the job in dead rather than retrying it' do
      define_job('KilledInterruptJob', retry: 10) { |*| raise 'boom' }
      KilledInterruptJob.cogworker_retry_in { |*| :kill }
      jid = KilledInterruptJob.perform_async

      processor.send(:process_one)

      expect(counts).to include(dead: 1, retry: 0)
      expect(deaths).to eq([[:handler, jid, RuntimeError, 'boom']])
    end
  end

  it 'runs only the death handlers, with the default backoff before that, for a class that no longer exists' do
    Cogworker::Client.push('class' => 'NoSuchJobAnymore', 'args' => [], 'retry' => 1)

    processor.send(:process_one)
    expect(entries(:retry).first.last - Time.now.to_f).to be_between(14, 75)
    graduate
    processor.send(:process_one)

    expect(counts).to include(dead: 1, retry: 0)
    expect(deaths.map(&:first)).to eq([:handler])
    expect(deaths.first[2]).to eq(NameError)
  end

  it 'runs no hooks for an unparseable payload' do
    Cogworker.config.redis { |c| c.lpush('cogworker:queue:default', 'not json') }

    processor.send(:process_one)

    expect(counts).to include(dead: 1)
    expect(deaths).to be_empty
  end

  it "extends the until_executed lock and the periodic running lock by the hook's delay plus unique_lock_ttl" do
    define_job('LockedJob', retry: 5, unique: :until_executed) { |*| raise 'boom' }
    LockedJob.cogworker_retry_in { |*| 100_000 }
    jid = Cogworker::Client.push('class' => 'LockedJob', 'args' => [], 'retry' => 5, 'unique' => 'until_executed',
                                 'periodic_pjid' => 'pj-locked')
    digest = queued_digest
    Cogworker.config.redis { |c| c.set('periodic:running:pj-locked', jid, ex: 60) }

    processor.send(:process_one)

    expected = 100_000 + Cogworker.config.unique_lock_ttl
    ttls = Cogworker.config.redis { |c| [c.ttl("cogworker:unique:#{digest}"), c.ttl('periodic:running:pj-locked')] }
    expect(ttls).to all(be_within(5).of(expected))
  end

  it "runs the death hooks only once the job is acknowledged, so a slow one can't get it requeued" do
    define_job('AckedFirstJob', retry: false) { |*| raise 'boom' }
    in_progress_seen = nil
    AckedFirstJob.cogworker_retries_exhausted do |*|
      in_progress_seen = Cogworker.config.redis { |c| c.llen("cogworker:inprogress:#{Cogworker.identity}") }
    end
    AckedFirstJob.perform_async

    processor.send(:process_one)

    expect(in_progress_seen).to eq(0)
  end

  it 'survives a death hook that exits — no second dead entry, no second call' do
    define_job('ExitingHookJob', retry: false) { |*| raise 'boom' }
    calls = 0
    ExitingHookJob.cogworker_retries_exhausted do |*|
      calls += 1
      exit 1
    end
    ExitingHookJob.perform_async

    expect { processor.send(:process_one) }.not_to raise_error

    expect(counts).to eq(retry: 0, dead: 1, queued: 0, in_progress: 0)
    expect(calls).to eq(1)
  end

  it 'passes a lambda with an optional parameter, and a #call object, only what they take' do
    define_job('OptionalArgJob', retry: 3) { |*| raise 'boom' }
    OptionalArgJob.cogworker_retry_in(&->(count, _exception = nil) { 1000 + count })
    callable = Class.new { def call(job, _exception) = job['jid'] }.new
    OptionalArgJob.perform_async

    processor.send(:process_one)

    expect(entries(:retry).first.last).to be_within(2).of(Time.now.to_f + 1000)
    expect(log.string).not_to include('raised')
    expect(Cogworker::JobUtil.call_hook(callable, { 'jid' => 'c1' }, RuntimeError.new, :extra)).to eq('c1')
  end

  it 'warns about a delay over a year, but uses it' do
    define_job('FarJob') { |*| raise 'boom' }
    FarJob.cogworker_retry_in { |*| 400 * 24 * 3600 }
    FarJob.perform_async

    processor.send(:process_one)

    expect(entries(:retry).first.last).to be_within(2).of(Time.now.to_f + (400 * 24 * 3600))
    expect(log.string).to include('(over a year)')
  end

  it 'corrects the status to failed when a middleware raised and the hook killed the job' do
    Cogworker::Status.configure_server_middleware(Cogworker.config, expiration: 60)
    failing = Class.new { def call(*) = raise(ArgumentError, 'middleware broke') }
    Cogworker.config.server_middleware { |chain| chain.add(failing) }
    define_job('MiddlewareKilledJob', retry: 10) { |*| nil }
    MiddlewareKilledJob.cogworker_retry_in { |*| :kill }
    jid = MiddlewareKilledJob.perform_async

    processor.send(:process_one)

    expect(counts).to include(dead: 1, retry: 0)
    expect(Cogworker::Status.status(jid)).to eq(:failed)
  end

  it 'writes, without any hooks, the same retry entry fields and default backoff as before' do
    Cogworker.config.death_handlers.clear
    define_job('PlainJob', retry: 3) { |*| raise 'boom' }
    PlainJob.perform_async
    pushed = JSON.parse(Cogworker.config.redis { |c| c.lindex('cogworker:queue:default', 0) })

    processor.send(:process_one)

    job, score = entries(:retry).first
    expect(job.keys).to match_array(pushed.keys + %w[error_class error_message failed_at retry_count])
    expect(job.except('error_class', 'error_message', 'failed_at', 'retry_count')).to eq(pushed)
    expect(score - Time.now.to_f).to be_between(14, 75)
  end
end
