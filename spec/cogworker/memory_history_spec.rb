# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Cogworker::MemoryHistory do
  let(:step) { described_class::SAMPLE_SECONDS }
  let(:now) { Time.utc(2026, 1, 2, 15, 30, 0).to_i } # a slot boundary

  def record(rss_kb, at)
    Cogworker.config.redis { |c| described_class.record(c, 'host:1', rss_kb, at: at) }
  end

  def values(at: now)
    described_class.series(['host:1'], now: at)['host:1'].map(&:last)
  end

  it 'always returns the full 24h — SLOTS slots, oldest first, ending with the current one — nil where empty' do
    slots = described_class.series(['host:1'], now: now + 5)['host:1']
    expect(slots.size).to eq(described_class::SLOTS)
    expect(slots.last).to eq([now, nil])
    expect(slots.first.first).to eq(now - ((described_class::SLOTS - 1) * step))
    expect(slots.map(&:last).uniq).to eq([nil])
  end

  it "keeps a slot's highest reading, whatever order the beats in it arrive in" do
    record(1000, now)
    record(3000, now + 5)
    record(2000, now + 10)
    record(1500, now + step)

    expect(values(at: now + step).last(2)).to eq([3000, 1500])
  end

  it 'drops slots older than the 24h window, and expires the key a little after it' do
    record(1000, now - described_class::WINDOW)
    record(2000, now)

    expect(values.compact).to eq([2000])
    ttl = Cogworker.config.redis { |c| c.ttl(Cogworker::RedisKeys.memory_history('host:1')) }
    expect(ttl).to be > described_class::WINDOW
  end

  it 'skips a beat that could not measure memory' do
    record(nil, now)

    expect(values.compact).to be_empty
  end
end
