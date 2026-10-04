# frozen_string_literal: true

require 'spec_helper'
require 'json'

RSpec.describe Cogworker::Scheduled do
  it 'graduates a due job from cogworker:schedule into its queue' do
    job = { 'jid' => 'abc', 'class' => 'X', 'queue' => 'default', 'args' => [] }
    raw = JSON.generate(job)
    Cogworker.config.redis { |c| c.zadd('cogworker:schedule', Time.now.to_f - 10, raw) }

    manager = instance_double(Cogworker::Manager, stopping?: false, quiet?: false)
    described_class.new(manager).send(:enqueue_due_jobs)

    expect(Cogworker.config.redis { |c| c.zcard('cogworker:schedule') }).to eq(0)
    queued = Cogworker.config.redis { |c| c.lrange('cogworker:queue:default', 0, -1) }.map { |r| JSON.parse(r) }
    expect(queued.map { |j| j.except('enqueued_at') }).to eq([job])
  end

  it 'does not graduate a job scheduled for the future' do
    job = { 'jid' => 'abc', 'class' => 'X', 'queue' => 'default', 'args' => [] }
    raw = JSON.generate(job)
    Cogworker.config.redis { |c| c.zadd('cogworker:schedule', Time.now.to_f + 3600, raw) }

    manager = instance_double(Cogworker::Manager, stopping?: false, quiet?: false)
    described_class.new(manager).send(:enqueue_due_jobs)

    expect(Cogworker.config.redis { |c| c.zcard('cogworker:schedule') }).to eq(1)
    expect(Cogworker.config.redis { |c| c.llen('cogworker:queue:default') }).to eq(0)
  end

  it 'keeps polling after a failed poll instead of letting the thread die' do
    manager = double(quiet?: false, fetch_class: Cogworker::ReliableFetch, running_jobs: [], pending_settlements: {},
                     queues: ['default'])
    allow(manager).to receive(:stopping?).and_return(false, false, true)
    scheduled = described_class.new(manager)
    calls = 0
    allow(scheduled).to receive(:enqueue_due_jobs) { (calls += 1) == 1 ? raise(Redis::CannotConnectError, 'blip') : nil }
    allow(scheduled).to receive(:sleep)

    expect { scheduled.send(:run) }.not_to raise_error
    expect(calls).to eq(2)
  end

  it 're-stamps enqueued_at when graduating, so queue latency reflects time spent in the queue only' do
    job = { 'class' => 'X', 'args' => [], 'queue' => 'default', 'jid' => 'j1', 'enqueued_at' => Time.now.to_f - 86_400 }
    Cogworker.config.redis { |c| c.zadd('cogworker:retry', Time.now.to_f - 1, JSON.generate(job)) }

    described_class.new(double(stopping?: false, quiet?: false)).send(:enqueue_due_jobs)

    queued = JSON.parse(Cogworker.config.redis { |c| c.rpop('cogworker:queue:default') })
    expect(queued['enqueued_at']).to be_within(5).of(Time.now.to_f)
    expect(Cogworker::Queue.new('default').latency).to be < 5
  end

  it 'buries an entry that is not a job in dead instead of losing it, and still graduates the rest of the poll' do
    good = JSON.generate('jid' => 'good', 'class' => 'X', 'queue' => 'default', 'args' => [])
    Cogworker.config.redis do |c|
      c.zadd('cogworker:retry', Time.now.to_f - 20, '{not json')
      c.zadd('cogworker:retry', Time.now.to_f - 10, good)
    end

    described_class.new(double(stopping?: false, quiet?: false)).send(:enqueue_due_jobs)

    expect(queued_jobs.map { |j| j['jid'] }).to eq(['good'])
    expect(Cogworker.config.redis { |c| c.zcard('cogworker:retry') }).to eq(0)
    dead = Cogworker.config.redis { |c| c.zrange('cogworker:dead', 0, -1) }.map { |raw| JSON.parse(raw) }
    expect(dead.map { |j| j.values_at('class', 'raw_payload') }).to eq([['(unparseable)', '{not json']])
    expect(Cogworker::Stats.new.failed).to eq(1) # counted like Processor#bury_unparseable
  end

  it 'only SCANs the keyspace for pre-set in-progress lists when this process itself uses ReliableFetch' do
    scans = []
    allow(Cogworker::ReliableFetch).to receive(:recover_orphans) { |scan:, **| scans << scan }

    described_class.new(double(fetch_class: Cogworker::BasicFetch)).send(:recover_orphans_if_due)
    described_class.new(double(fetch_class: Cogworker::ReliableFetch, running_jobs: [], pending_settlements: {},
                               queues: ['default'])).send(:recover_orphans_if_due)

    expect(scans).to eq([false, true])
  end

  it 'reports its first orphan check done only once one has completed, ' \
     'and retries a failed one a check interval later' do
    scheduled = described_class.new(double(fetch_class: Cogworker::BasicFetch))
    calls = 0
    allow(Cogworker::ReliableFetch).to receive(:recover_orphans) do |report:, **|
      raise Redis::CannotConnectError, 'down' if (calls += 1) == 1

      report[:registry] = true
    end

    expect { scheduled.send(:recover_orphans_if_due) }.to raise_error(Redis::CannotConnectError)
    expect(scheduled).not_to be_recovered_once
    scheduled.send(:recover_orphans_if_due)
    expect(calls).to eq(1) # not on every poll

    scheduled.instance_variable_set(:@next_orphan_check, 0)
    scheduled.send(:recover_orphans_if_due)
    expect(calls).to eq(2)
    expect(scheduled).to be_recovered_once
  end

  describe 'with an in-progress identity that can\'t be processed' do
    before do
      Cogworker.config.redis do |c|
        c.sadd?('cogworker:inprogress_identities', 'ghost')
        c.set('cogworker:inprogress:ghost', 'x') # wrong type: every list command on it raises WRONGTYPE
        c.sadd?('cogworker:inprogress_identities', 'dead-host:1:a')
        c.lpush('cogworker:inprogress:dead-host:1:a', JSON.generate('jid' => 'orphan', 'queue' => 'default'))
      end
      allow(Cogworker).to receive(:logger).and_return(Cogworker::Logging.default_logger(StringIO.new))
    end

    it 'skips just that identity: the others are still recovered, and the first check still completes' do
      scheduled = described_class.new(Cogworker::Manager.new)

      scheduled.send(:recover_orphans_if_due)

      expect(scheduled).to be_recovered_once
      expect(queued_jobs.map { |j| j['jid'] }).to eq(['orphan'])
    end

    it 'still graduates due scheduled jobs on the same poll, whatever recovery does' do
      Cogworker::Client.push('class' => 'X', 'args' => [], 'at' => Time.now.to_f - 5)
      allow(Cogworker::ReliableFetch).to receive(:recover_orphans).and_raise(Redis::CommandError, 'boom')
      manager = double(quiet?: false, fetch_class: Cogworker::ReliableFetch, running_jobs: [], pending_settlements: {},
                       queues: ['default'])
      allow(manager).to receive(:stopping?).and_return(false, true)
      scheduled = described_class.new(manager)
      allow(scheduled).to receive(:sleep)

      scheduled.send(:run)

      expect(Cogworker.config.redis { |c| c.zcard('cogworker:schedule') }).to eq(0)
      expect(queued_jobs.map { |j| j['class'] }).to eq(['X']) # graduated, though recovery itself failed
    end
  end

  it "doesn't let the ticker start on a pass that lost the connection part-way, and retries it on the next poll" do
    allow(Cogworker).to receive(:logger).and_return(Cogworker::Logging.default_logger(StringIO.new))
    Cogworker.config.redis do |c|
      c.sadd?('cogworker:inprogress_identities', 'dead:1:a')
      c.lpush('cogworker:inprogress:dead:1:a', JSON.generate('jid' => 'j', 'queue' => 'default'))
    end
    allow(Cogworker::ReliableFetch).to receive(:recover_identity).and_raise(Redis::CannotConnectError, 'gone')
    scheduled = described_class.new(Cogworker::Manager.new)

    scheduled.send(:recover_orphans_if_due)

    expect(scheduled.ready_for_ticker?).to be(false)
    next_check = scheduled.instance_variable_get(:@next_orphan_check)
    expect(next_check - ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)).to be <= described_class::POLL_INTERVAL
  end

  describe 'isolation while polling' do
    before { allow(Cogworker).to receive(:logger).and_return(Cogworker::Logging.default_logger(StringIO.new)) }

    let(:due) { JSON.generate('jid' => 'r1', 'class' => 'X', 'queue' => 'default', 'args' => []) }

    it "still graduates cogworker:retry when cogworker:schedule isn't a sorted set" do
      Cogworker.config.redis do |c|
        c.set('cogworker:schedule', 'not a zset')
        c.zadd('cogworker:retry', Time.now.to_f - 1, due)
      end

      described_class.new(double).send(:enqueue_due_jobs)

      expect(queued_jobs.map { |j| j['jid'] }).to eq(['r1'])
    end

    it 'still graduates the rest of a batch when one entry fails' do
      bad = JSON.generate('jid' => 'r0', 'class' => 'X', 'queue' => 'broken', 'args' => [])
      Cogworker.config.redis do |c|
        c.set('cogworker:queue:broken', 'not a list')
        c.zadd('cogworker:retry', Time.now.to_f - 2, bad)
        c.zadd('cogworker:retry', Time.now.to_f - 1, due)
      end

      described_class.new(double).send(:enqueue_due_jobs)

      expect(queued_jobs.map { |j| j['jid'] }).to eq(['r1'])
      expect(Cogworker.config.redis { |c| c.zrange('cogworker:retry', 0, -1) }).to eq([bad]) # kept, not lost
      deferred_to = Cogworker.config.redis { |c| c.zscore('cogworker:retry', bad) }
      expect(deferred_to).to be_within(5).of(Time.now.to_f + described_class::DEFER_DELAY) # out of the way
    end

    it "still recovers by scanning when the in-progress registry isn't a set" do
      Cogworker.config.redis do |c|
        c.set('cogworker:inprogress_identities', 'not a set')
        c.lpush('cogworker:inprogress:dead-host:7:q', JSON.generate('jid' => 'o1', 'queue' => 'default'))
      end

      expect(Cogworker::ReliableFetch.recover_orphans(scan: true)).to eq(1)
    end
  end

  it "doesn't count a pass that couldn't read any source of candidates as the first recovery, nor the SCAN as done" do
    allow(Cogworker).to receive(:logger).and_return(Cogworker::Logging.default_logger(StringIO.new))
    Cogworker.config.redis { |c| c.set('cogworker:inprogress_identities', 'x') }
    allow_any_instance_of(Redis).to receive(:scan_each).and_raise(Redis::CommandError, 'scan refused')
    scheduled = described_class.new(Cogworker::Manager.new)

    scheduled.send(:recover_orphans_if_due)

    expect(scheduled).not_to be_recovered_once
    expect(scheduled.instance_variable_get(:@scanned)).to be_falsey
  end
end
