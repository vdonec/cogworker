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

  describe 'cogworker_retry_in / cogworker_retries_exhausted' do
    it 'keeps each block on the class, readable through *_block, nil when never set' do
      retry_in = proc { |count| count }
      exhausted = proc { |_job, _e| nil }
      TestJob.cogworker_retry_in(&retry_in)
      TestJob.cogworker_retries_exhausted(&exhausted)

      expect(TestJob.cogworker_retry_in_block).to equal(retry_in)
      expect(TestJob.cogworker_retries_exhausted_block).to equal(exhausted)
      stub_const('BareJob', Class.new { include Cogworker::Worker })
      expect(BareJob.cogworker_retry_in_block).to be_nil
      expect(BareJob.cogworker_retries_exhausted_block).to be_nil
    end

    it 'is inherited, and a subclass overrides it without touching its parent' do
      stub_const('BaseJob', Class.new { include Cogworker::Worker })
      BaseJob.cogworker_retry_in { |count| count * 10 }
      BaseJob.cogworker_retries_exhausted { |_job, _e| :base }
      stub_const('ChildJob', Class.new(BaseJob))
      stub_const('OwnJob', Class.new(BaseJob))
      OwnJob.cogworker_retry_in { |_count| :kill }

      expect(ChildJob.cogworker_retry_in_block.call(2)).to eq(20)
      expect(ChildJob.cogworker_retries_exhausted_block.call({}, nil)).to eq(:base)
      expect(OwnJob.cogworker_retry_in_block.call(2)).to eq(:kill)
      expect(BaseJob.cogworker_retry_in_block.call(2)).to eq(20)
    end

    it 'keeps the blocks out of the pushed payload' do
      TestJob.cogworker_retry_in { |_count| 5 }
      TestJob.cogworker_retries_exhausted { |_job, _e| nil }

      TestJob.perform_async(1)

      raw = Cogworker.config.redis { |c| c.lrange('cogworker:queue:default', 0, -1) }.first
      expect(raw).not_to include('retry_in', 'exhausted', 'Proc')
      expect(TestJob.cogworker_options_hash.keys).to eq(%i[lock_run retry])
    end

    it 'raises ArgumentError without a block' do
      expect { TestJob.cogworker_retry_in }.to raise_error(ArgumentError)
      expect { TestJob.cogworker_retries_exhausted }.to raise_error(ArgumentError)
    end
  end
end
