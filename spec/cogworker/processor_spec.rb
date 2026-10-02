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
      digest = Cogworker::UniqueJobs.digest(JSON.parse(JSON.generate({ 'class' => 'X', 'queue' => 'default', 'args' => [] })))
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

    it "still runs a job whose registration in cogworker:workers fails (the key holding the wrong type)" do
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

    strays = []
    2.times do
      strays = Cogworker::ReliableFetch.reconcile(Cogworker.identity, strays, running: manager.running_jobs,
                                                                              pending: manager.pending_settlements) { |raw| manager.settled(raw) }
    end
    expect(queued_jobs).to be_empty # not requeued as a stray

    Cogworker.config.redis { |c| c.del('cogworker:dead') } # Redis is fine again
    Cogworker::ReliableFetch.reconcile(Cogworker.identity, strays, running: manager.running_jobs,
                                                                   pending: manager.pending_settlements) { |raw| manager.settled(raw) }

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

  it "hands an unfileable failure over to cogworker:unsettled on shutdown — never requeues it — and it's filed once possible",
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
end
