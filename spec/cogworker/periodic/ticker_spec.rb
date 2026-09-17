# frozen_string_literal: true

require 'spec_helper'

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
