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
    manager = double(quiet?: false, fetch_class: Cogworker::ReliableFetch)
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
    allow(Cogworker::ReliableFetch).to receive(:recover_orphans) { |scan:| scans << scan }

    described_class.new(double(fetch_class: Cogworker::BasicFetch)).send(:recover_orphans_if_due)
    described_class.new(double(fetch_class: Cogworker::ReliableFetch)).send(:recover_orphans_if_due)

    expect(scans).to eq([false, true])
  end

  it 'reports its first orphan check done only once one has completed, and retries a failed one on the next poll' do
    scheduled = described_class.new(double(fetch_class: Cogworker::BasicFetch))
    calls = 0
    allow(Cogworker::ReliableFetch).to receive(:recover_orphans) { raise Redis::CannotConnectError, 'down' if (calls += 1) == 1 }

    expect { scheduled.send(:recover_orphans_if_due) }.to raise_error(Redis::CannotConnectError)
    expect(scheduled).not_to be_recovered_once
    scheduled.send(:recover_orphans_if_due)

    expect(calls).to eq(2)
    expect(scheduled).to be_recovered_once
  end
end
