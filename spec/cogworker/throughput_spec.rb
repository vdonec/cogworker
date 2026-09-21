# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Cogworker::Throughput do
  it 'records processed/failed into the current hour bucket, independently' do
    now = Time.utc(2026, 1, 2, 15, 30, 0)
    described_class.record('processed', at: now)
    described_class.record('processed', at: now)
    described_class.record('failed', at: now)

    series = described_class.series(hours: 1, now: now)
    expect(series.size).to eq(1)
    expect(series.first['processed']).to eq(2)
    expect(series.first['failed']).to eq(1)
    expect(series.first['time']).to eq(Time.utc(2026, 1, 2, 15, 0, 0))
  end

  it 'keeps separate hours as separate buckets, oldest first' do
    hour1 = Time.utc(2026, 1, 2, 10, 0, 0)
    hour2 = Time.utc(2026, 1, 2, 11, 0, 0)
    described_class.record('processed', at: hour1)
    described_class.record('processed', at: hour2)
    described_class.record('processed', at: hour2)

    series = described_class.series(hours: 2, now: hour2)
    expect(series.map { |e| e['processed'] }).to eq([1, 2])
    expect(series.map { |e| e['time'] }).to eq([hour1, hour2])
  end

  it "fills in an hour with no activity as a real 0, not a skipped gap" do
    now = Time.utc(2026, 1, 2, 12, 0, 0)
    described_class.record('processed', at: now)

    series = described_class.series(hours: 3, now: now)
    expect(series.size).to eq(3)
    expect(series.map { |e| e['processed'] }).to eq([0, 0, 1])
  end

  it 'sets a TTL on a bucket so an old one eventually expires on its own' do
    described_class.record('processed')
    ttl = Cogworker.config.redis { |c| c.ttl(Cogworker::RedisKeys.throughput_bucket(described_class.bucket_for(Time.now))) }
    expect(ttl).to be_between(1, described_class::BUCKET_TTL)
  end
end
