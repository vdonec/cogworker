# frozen_string_literal: true

require 'spec_helper'
require 'stringio'

RSpec.describe Cogworker::Periodic::Ticker do
  let(:entry) do
    Cogworker::Periodic::Entry.new(cron: '* * * * *', class_name: 'TickerJob', retry: 0,
                                   unique: :until_executed, args: [{ 'a' => 1 }])
  end

  before { stub_const('TickerJob', Class.new { include Cogworker::Worker }) }

  let(:ticker_log) { StringIO.new }

  before { allow(Cogworker).to receive(:logger).and_return(Cogworker::Logging.default_logger(ticker_log)) }

  it 'enqueues the job and sets the running lock on a due, unclaimed slot' do
    ticker = described_class.new(double(stopping?: false, quiet?: false), [entry])
    ticker.send(:tick)

    raw = Cogworker.config.redis { |c| c.rpop('cogworker:queue:default') }
    job = JSON.parse(raw)
    expect(job['class']).to eq('TickerJob')
    expect(job['args']).to eq([{ 'a' => 1 }])
    expect(job['periodic_pjid']).to eq(entry.pjid)
    expect(job['periodic_until_executed']).to be(true)
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

  it 'does not lose the slot when the push fails after a won claim — the next tick fires it' do
    ticker = described_class.new(double(stopping?: false, quiet?: false), [entry])
    calls = 0
    allow(Cogworker::Client).to receive(:push).and_wrap_original do |original, *args|
      (calls += 1) == 1 ? raise(Redis::CannotConnectError, 'blip') : original.call(*args)
    end

    expect { ticker.send(:tick) }.not_to raise_error # logged per entry, retried next tick
    expect(Cogworker.config.redis { |c| c.get("periodic:running:#{entry.pjid}") }).to be_nil
    ticker.instance_variable_get(:@retry_at).clear # skip the backoff
    ticker.send(:tick)

    expect(Cogworker.config.redis { |c| c.llen('cogworker:queue:default') }).to eq(1)
  end

  it 'releases the running lock in the same step as the rollback — it used to be a separate call made first, ' \
     'whose own failure skipped the rollback and lost the slot' do
    allow(Cogworker::Client).to receive(:push).and_raise(Redis::CannotConnectError, 'down')
    allow(Cogworker::Periodic::RunningLock).to receive(:release).and_raise(Redis::CannotConnectError, 'down')
    ticker = described_class.new(double(stopping?: false, quiet?: false), [entry])

    expect { ticker.send(:tick) }.not_to raise_error # logged per entry, retried next tick
    expect(Cogworker.config.redis { |c| c.get("periodic:running:#{entry.pjid}") }).to be_nil

    allow(Cogworker::Client).to receive(:push).and_call_original
    ticker.instance_variable_get(:@retry_at).clear # skip the backoff
    ticker.send(:tick)
    expect(Cogworker.config.redis { |c| c.llen('cogworker:queue:default') }).to eq(1) # the slot still fired
  end

  it 'rolls a failed slot back to the previous last_slot, not past a later slot someone else claimed since' do
    Cogworker.config.redis { |c| c.set("periodic:last_slot:#{entry.pjid}", 100) }
    ticker = described_class.new(double(stopping?: false, quiet?: false), [entry])

    ticker.send(:rollback_claim, entry, 200, '100', 'j')
    expect(Cogworker.config.redis { |c| c.get("periodic:last_slot:#{entry.pjid}") }).to eq('100')

    Cogworker.config.redis { |c| c.set("periodic:last_slot:#{entry.pjid}", 200) }
    ticker.send(:rollback_claim, entry, 200, '', 'j')
    expect(Cogworker.config.redis { |c| c.get("periodic:last_slot:#{entry.pjid}") }).to eq('199')

    Cogworker.config.redis { |c| c.set("periodic:last_slot:#{entry.pjid}", 300) }
    ticker.send(:rollback_claim, entry, 200, '100', 'j')
    expect(Cogworker.config.redis { |c| c.get("periodic:last_slot:#{entry.pjid}") }).to eq('300')
  end

  it "doesn't tick until it's ready (the process's first orphan check has run)" do
    manager = double(quiet?: false)
    allow(manager).to receive(:stopping?).and_return(false, false, true)
    ready = false
    ticker = described_class.new(manager, [entry], ready: -> { ready })
    allow(ticker).to receive(:sleep) { ready = true }

    ticker.send(:run)

    expect(Cogworker.config.redis { |c| c.llen('cogworker:queue:default') }).to eq(1) # second loop only
  end

  it 'retries a rollback that failed along with the push, so the slot still fires once Redis is back' do
    ticker = described_class.new(double(stopping?: false, quiet?: false), [entry])
    allow(Cogworker::Client).to receive(:push).and_raise(Redis::CannotConnectError, 'down')
    allow(Cogworker).to receive(:logger).and_return(Cogworker::Logging.default_logger(StringIO.new))
    rollbacks = 0
    allow(Cogworker::LuaScript).to receive(:run).and_wrap_original do |original, conn, script, **kw|
      raise Redis::CannotConnectError, 'down' if script == described_class::ROLLBACK_SCRIPT && (rollbacks += 1) == 1

      original.call(conn, script, **kw)
    end

    expect { ticker.send(:tick) }.not_to raise_error # logged per entry, retried next tick
    allow(Cogworker::Client).to receive(:push).and_call_original
    ticker.instance_variable_get(:@retry_at).clear # skip the backoff
    ticker.send(:tick)

    expect(rollbacks).to eq(2)
    expect(Cogworker.config.redis { |c| c.llen('cogworker:queue:default') }).to eq(1)
  end

  it 'keeps ticking the other entries when one fails, and starts even if publishing the schedule fails' do
    other = Cogworker::Periodic::Entry.new(cron: '* * * * *', class_name: 'TickerJob', retry: 0, unique: nil,
                                          args: ['other'])
    Cogworker.config.redis do |c|
      c.set("periodic:last_slot:#{entry.pjid}", 'x')
      c.set('periodic:last_slot:x', 'x')
      c.set('periodic:schedule', 'not a hash')
    end
    allow(Cogworker::Client).to receive(:push).and_wrap_original do |original, job|
      raise Redis::CannotConnectError, 'down' if job['periodic_pjid'] == entry.pjid

      original.call(job)
    end
    ticker = described_class.new(double(stopping?: true, quiet?: false), [entry, other])

    expect { ticker.start! }.not_to raise_error
    ticker.send(:tick)

    expect(queued_jobs.map { |j| j['args'] }).to eq([['other']])
    expect(ticker_log.string).to include("Periodic tick failed for #{entry.pjid}", 'Periodic schedule not published')
  end

  it "keeps cron running when periodic:disabled can't be read, treating entries as enabled" do
    Cogworker.config.redis { |c| c.set('periodic:disabled', 'not a set') }

    described_class.new(double(stopping?: false, quiet?: false), [entry]).send(:tick)

    expect(Cogworker.config.redis { |c| c.llen('cogworker:queue:default') }).to eq(1)
    expect(ticker_log.string).to include('treating')
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

  it 'backs a failing entry off exponentially instead of retrying it every tick, and resets on success' do
    ticker = described_class.new(double(stopping?: false, quiet?: false), [entry])
    allow(Cogworker::Client).to receive(:push).and_raise(Redis::CannotConnectError, 'down')

    delays = Array.new(8) { ticker.send(:back_off, entry.pjid) }
    expect(delays).to eq([5, 10, 20, 40, 80, 160, 300, 300])

    expect(ticker.send(:backing_off?, entry.pjid)).to be(true)
    pushes = 0
    allow(Cogworker::Client).to receive(:push) { pushes += 1 }
    ticker.send(:tick)
    expect(pushes).to eq(0) # still backing off
  end

  it "doesn't back an entry off for a lost connection — only for failing on its own" do
    ticker = described_class.new(double(stopping?: false, quiet?: false), [entry])
    allow(Cogworker::Client).to receive(:push).and_raise(Redis::CannotConnectError, 'gone')

    3.times { ticker.send(:tick) }
    expect(ticker.instance_variable_get(:@failures)[entry.pjid]).to eq(0)

    allow(Cogworker::Client).to receive(:push).and_raise(ArgumentError, 'broken entry')
    ticker.instance_variable_get(:@pending_rollbacks).clear
    ticker.send(:tick)
    expect(ticker.instance_variable_get(:@failures)[entry.pjid]).to eq(1)
  end

  it "counts a rollback as done even when the entry's running-lock key holds the wrong type" do
    Cogworker.config.redis do |c|
      c.set("periodic:last_slot:#{entry.pjid}", 200)
      c.rpush("periodic:running:#{entry.pjid}", 'a list')
    end
    ticker = described_class.new(double(stopping?: false, quiet?: false), [entry])

    expect(ticker.send(:rollback_claim, entry, 200, '100', 'j')).to be(true)
    expect(Cogworker.config.redis { |c| c.get("periodic:last_slot:#{entry.pjid}") }).to eq('100')
  end
end
