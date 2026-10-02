# frozen_string_literal: true

require 'spec_helper'
require 'stringio'

RSpec.describe Cogworker::Periodic::Ticker do
  let(:entry) do
    Cogworker::Periodic::Entry.new(cron: '* * * * *', class_name: 'TickerJob', retry: 0,
                                   unique: :until_executed, args: [{ 'a' => 1 }])
  end

  before { stub_const('TickerJob', Class.new { include Cogworker::Worker }) }

  it 'enqueues the job and sets the running lock on a due, unclaimed slot' do
    ticker = described_class.new(double(stopping?: false, quiet?: false), [entry])
    ticker.send(:tick)

    raw = Cogworker.config.redis { |c| c.rpop('cogworker:queue:default') }
    job = JSON.parse(raw)
    expect(job['class']).to eq('TickerJob')
    expect(job['args']).to eq([{ 'a' => 1 }])
    expect(job['periodic_pjid']).to eq(entry.pjid)
    expect(Cogworker.config.redis { |c| c.get("periodic:running:#{entry.pjid}") }).to eq(job['jid'])
  end

  it 'gives the running lock a TTL, so a run whose process dies cannot hold the entry forever' do
    described_class.new(double(stopping?: false, quiet?: false), [entry]).send(:tick)

    ttl = Cogworker.config.redis { |c| c.ttl("periodic:running:#{entry.pjid}") }
    expect(ttl).to be_between(1, Cogworker.config.unique_lock_ttl)
  end

  it 'does not leave the running lock behind when the job finishes before Client.push even returns ' \
     '(regression: the lock used to be written after the push, resurrecting a lock the job had already released)' do
    TickerJob.define_method(:perform) { |*| nil }
    Cogworker::Testing.inline! do
      described_class.new(double(stopping?: false, quiet?: false), [entry]).send(:tick)
    end

    expect(Cogworker.config.redis { |c| c.get("periodic:running:#{entry.pjid}") }).to be_nil
  end

  it 'releases the running lock when the push produced no job' do
    allow(Cogworker::Client).to receive(:push).and_return(nil)
    described_class.new(double(stopping?: false, quiet?: false), [entry]).send(:tick)

    expect(Cogworker.config.redis { |c| c.get("periodic:running:#{entry.pjid}") }).to be_nil
  end

  it 'keeps ticking after a failed tick instead of letting the thread die' do
    manager = double(quiet?: false)
    allow(manager).to receive(:stopping?).and_return(false, false, true)
    ticker = described_class.new(manager, [entry])
    calls = 0
    allow(ticker).to receive(:tick) { (calls += 1) == 1 ? raise(Redis::CannotConnectError, 'blip') : nil }
    allow(ticker).to receive(:sleep)

    expect { ticker.send(:run) }.not_to raise_error
    expect(calls).to eq(2)
  end

  it 'still claims with a fractional unique_lock_ttl (SET ... EX only takes whole seconds)' do
    Cogworker.config.unique_lock_ttl = 3600.5
    described_class.new(double(stopping?: false, quiet?: false), [entry]).send(:tick)

    expect(Cogworker.config.redis { |c| c.llen('cogworker:queue:default') }).to eq(1)
    expect(Cogworker.config.redis { |c| c.ttl("periodic:running:#{entry.pjid}") }).to be_between(3600, 3601)
  end

  it 'warns when a client middleware changed the jid the running lock was claimed under' do
    allow(Cogworker::Client).to receive(:push).and_return('rewritten-jid')
    log = StringIO.new
    allow(Cogworker).to receive(:logger).and_return(Cogworker::Logging.default_logger(log))

    described_class.new(double(stopping?: false, quiet?: false), [entry]).send(:tick)

    expect(log.string).to include("changed the job's jid")
  end

  it "skips claim/enqueue entirely for a disabled entry (Routes::Schedules' own \"Disable\") — no job, " \
     "no running lock, and periodic:last_slot doesn't advance either" do
    Cogworker.config.redis { |c| c.sadd?('periodic:disabled', entry.pjid) }
    ticker = described_class.new(double(stopping?: false, quiet?: false), [entry])

    ticker.send(:tick)

    expect(Cogworker.config.redis { |c| c.llen('cogworker:queue:default') }).to eq(0)
    expect(Cogworker.config.redis { |c| c.get("periodic:running:#{entry.pjid}") }).to be_nil
    expect(Cogworker.config.redis { |c| c.get("periodic:last_slot:#{entry.pjid}") }).to be_nil
  end

  it 're-enabling an entry lets it be claimed again — nothing about the disabled window left ' \
     'periodic:last_slot/the per-slot lock advanced, so a fresh claim attempt for that same slot ' \
     "still succeeds (a *second* Ticker instance here, matching this spec's own race test just below: " \
     'the first instance\'s own in-memory @last_checked_slot would otherwise mask this, since — exactly ' \
     'like a lost claim race already does — it dedups a slot it saw at all, disabled or not, and doesn\'t ' \
     're-check it again until the cron rolls over to a new one)' do
    Cogworker.config.redis { |c| c.sadd?('periodic:disabled', entry.pjid) }
    described_class.new(double(stopping?: false, quiet?: false), [entry]).send(:tick)
    expect(Cogworker.config.redis { |c| c.llen('cogworker:queue:default') }).to eq(0)

    Cogworker.config.redis { |c| c.srem?('periodic:disabled', entry.pjid) }
    described_class.new(double(stopping?: false, quiet?: false), [entry]).send(:tick)

    expect(Cogworker.config.redis { |c| c.llen('cogworker:queue:default') }).to eq(1)
  end

  it 'does not set a running lock for a non until_executed entry' do
    plain_entry = Cogworker::Periodic::Entry.new(cron: '* * * * *', class_name: 'TickerJob', retry: 0,
                                                 unique: nil, args: [])
    ticker = described_class.new(double(stopping?: false, quiet?: false), [plain_entry])
    ticker.send(:tick)

    expect(Cogworker.config.redis { |c| c.get("periodic:running:#{plain_entry.pjid}") }).to be_nil
    expect(Cogworker.config.redis { |c| c.llen('cogworker:queue:default') }).to eq(1)
  end

  it 'does not re-claim the same slot on a second tick within the same process' do
    ticker = described_class.new(double(stopping?: false, quiet?: false), [entry])
    ticker.send(:tick)
    ticker.send(:tick)

    expect(Cogworker.config.redis { |c| c.llen('cogworker:queue:default') }).to eq(1)
  end

  it 'lets exactly one of two independent tickers (simulating two processes) win the same slot' do
    manager = double(stopping?: false, quiet?: false)
    ticker_a = described_class.new(manager, [entry])
    ticker_b = described_class.new(manager, [entry])

    ticker_a.send(:tick)
    ticker_b.send(:tick)

    expect(Cogworker.config.redis { |c| c.llen('cogworker:queue:default') }).to eq(1)
  end

  it 'publishes the entries to periodic:schedule on start!' do
    ticker = described_class.new(double(stopping?: true, quiet?: false), [entry])
    ticker.start!

    stored = Cogworker.config.redis { |c| c.hget('periodic:schedule', entry.pjid) }
    parsed = JSON.parse(stored)
    expect(parsed['class']).to eq('TickerJob')
    expect(parsed['unique']).to eq('until_executed')
  end

  describe 'catch_up: false' do
    it 'does not enqueue the most-recently-due slot on a cold start (no persisted last_slot yet)' do
      ticker = described_class.new(double(stopping?: false, quiet?: false), [entry], catch_up: false)
      ticker.send(:tick)

      expect(Cogworker.config.redis { |c| c.llen('cogworker:queue:default') }).to eq(0)
      expect(Cogworker.config.redis { |c| c.get("periodic:last_slot:#{entry.pjid}") }).not_to be_nil
    end

    it 'does not enqueue when two processes race the same cold-start slot' do
      manager = double(stopping?: false, quiet?: false)
      ticker_a = described_class.new(manager, [entry], catch_up: false)
      ticker_b = described_class.new(manager, [entry], catch_up: false)

      ticker_a.send(:tick)
      ticker_b.send(:tick)

      expect(Cogworker.config.redis { |c| c.llen('cogworker:queue:default') }).to eq(0)
    end

    it 'still catches up an entry that has already run before (last_slot already persisted)' do
      Cogworker.config.redis { |c| c.set("periodic:last_slot:#{entry.pjid}", 0) }
      ticker = described_class.new(double(stopping?: false, quiet?: false), [entry], catch_up: false)
      ticker.send(:tick)

      expect(Cogworker.config.redis { |c| c.llen('cogworker:queue:default') }).to eq(1)
    end
  end
end
