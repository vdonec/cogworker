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
    manager = double(quiet?: false)
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
end
