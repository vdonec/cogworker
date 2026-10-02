# frozen_string_literal: true

require 'spec_helper'
require 'stringio'

RSpec.describe Cogworker::KeyGuard do
  let(:log) { StringIO.new }

  before { allow(Cogworker).to receive(:logger).and_return(Cogworker::Logging.default_logger(log)) }

  def type(key) = Cogworker.config.redis { |c| c.type(key) }

  it 'moves keys holding the wrong type into quarantine, keeping their data, and leaves the rest alone' do
    Cogworker.config.redis do |c|
      c.set('cogworker:dead', 'not a zset')
      c.sadd?('cogworker:queues', 'broken')
      c.set('cogworker:queue:broken', 'not a list')
      c.lpush('cogworker:queue:default', 'fine')
      c.zadd('cogworker:retry', 1, 'fine')
    end

    quarantined = described_class.check(queues: ['default'])

    expect(quarantined).to contain_exactly('cogworker:dead', 'cogworker:queue:broken')
    expect([type('cogworker:dead'), type('cogworker:queue:broken')]).to eq(%w[none none])
    expect([type('cogworker:queue:default'), type('cogworker:retry')]).to eq(%w[list zset])
    kept = Cogworker.config.redis { |c| c.keys('cogworker:quarantine:cogworker:dead:*') }
    expect(Cogworker.config.redis { |c| c.get(kept.first) }).to eq('not a zset')
    expect(Cogworker.config.redis { |c| c.ttl(kept.first) }).to be > 0
    expect(log.string).to include('cogworker:dead held a string, not a zset')
  end

  it 'checks per-process keys listed in a registry, even after the registry itself is quarantined next round' do
    Cogworker.config.redis do |c|
      c.sadd?('cogworker:inprogress_identities', 'h:1:a')
      c.set('cogworker:inprogress:h:1:a', 'x')
    end

    expect(described_class.check).to eq(['cogworker:inprogress:h:1:a'])

    Cogworker.config.redis { |c| c.set('cogworker:inprogress_identities', 'x') }
    expect(described_class.check).to eq(['cogworker:inprogress_identities'])
  end

  it 'lets the system recover from a broken key on its own: a retry: false job lands in dead after a check' do
    Cogworker.config.redis { |c| c.set('cogworker:dead', 'x') }
    described_class.check

    Cogworker.config.redis { |c| c.zadd('cogworker:dead', 1, '{}') }
    expect(type('cogworker:dead')).to eq('zset')
  end

  it 'keeps both copies when the same key is quarantined twice within one second' do
    2.times do
      Cogworker.config.redis { |c| c.set('cogworker:dead', 'x') }
      described_class.check
    end

    expect(Cogworker.config.redis { |c| c.keys('cogworker:quarantine:cogworker:dead:*') }.size).to eq(2)
  end
end
