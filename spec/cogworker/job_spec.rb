# frozen_string_literal: true

require 'spec_helper'
require 'json'

RSpec.describe Cogworker::Job do
  before do
    stub_const('TestJob', Class.new do
      include Cogworker::Worker

      cogworker_options lock_run: :while_executing
      cogworker_options retry: false

      def perform(*); end
    end)
  end

  it 'preserves arbitrary custom cogworker_options keys, merged across calls, both syntaxes' do
    expect(TestJob.cogworker_options_hash).to eq(lock_run: :while_executing, retry: false)
  end

  it 'is also reachable via the Cogworker::Job alias' do
    expect(Cogworker::Job).to equal(Cogworker::Worker)
  end

  describe '.perform_async' do
    it 'pushes a job hash carrying custom options into the default queue' do
      jid = TestJob.perform_async(1, 'two')

      raw = Cogworker.config.redis { |c| c.lpop('cogworker:queue:default') }
      job = JSON.parse(raw)

      expect(job['jid']).to eq(jid)
      expect(job['class']).to eq('TestJob')
      expect(job['args']).to eq([1, 'two'])
      expect(job['queue']).to eq('default')
      expect(job['lock_run']).to eq('while_executing')
      expect(job['retry']).to eq(false)
    end

    it 'registers the queue name for introspection' do
      TestJob.perform_async
      expect(Cogworker.config.redis { |c| c.smembers('cogworker:queues') }).to eq(['default'])
    end
  end

  describe '.perform_in / .perform_at' do
    it 'schedules a small interval as seconds-from-now into the schedule zset' do
      TestJob.perform_in(60, 'x')

      score = Cogworker.config.redis { |c| c.zscore('cogworker:schedule', c.zrange('cogworker:schedule', 0, 0).first) }
      expect(score).to be_within(2).of(Time.now.to_f + 60)
    end

    it 'treats a large value as an absolute unix timestamp' do
      future = Time.now.to_f + 10_000
      TestJob.perform_at(future)

      score = Cogworker.config.redis { |c| c.zscore('cogworker:schedule', c.zrange('cogworker:schedule', 0, 0).first) }
      expect(score).to be_within(1).of(future)
    end
  end
end
