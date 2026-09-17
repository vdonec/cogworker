# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Cogworker::Testing do
  before do
    stub_const('TestingJob', Class.new do
      include Cogworker::Worker

      def self.calls
        @calls ||= []
      end

      def perform(*args)
        self.class.calls << args
      end
    end)
  end

  it 'defaults to disabled, pushing onto real Redis like any non-test run' do
    expect(described_class).to be_disabled

    TestingJob.perform_async(1)

    expect(Cogworker.config.redis { |c| c.llen('cogworker:queue:default') }).to eq(1)
  end

  describe '.fake!' do
    before { described_class.fake! }

    it 'records the pushed job instead of touching Redis' do
      jid = TestingJob.perform_async(1, 'two')

      expect(Cogworker.config.redis { |c| c.llen('cogworker:queue:default') }).to eq(0)
      expect(TestingJob.jobs.size).to eq(1)
      expect(TestingJob.jobs.first).to include('jid' => jid, 'class' => 'TestingJob', 'args' => [1, 'two'])
    end

    it 'never actually runs the job' do
      TestingJob.perform_async(1)
      expect(TestingJob.calls).to eq([])
    end

    it 'records perform_in/perform_at entries too, carrying their scheduled "at"' do
      TestingJob.perform_in(60, 'x')
      expect(TestingJob.jobs.first['at']).to be_a(Float)
    end

    it 'lets .clear reset just that class, independent of other classes' do
      stub_const('OtherTestingJob', Class.new do
        include Cogworker::Worker
        def perform(*); end
      end)

      TestingJob.perform_async
      OtherTestingJob.perform_async

      TestingJob.clear

      expect(TestingJob.jobs).to be_empty
      expect(OtherTestingJob.jobs.size).to eq(1)
    end
  end

  describe '.inline!' do
    before { described_class.inline! }

    it 'runs the job synchronously in the calling thread, touching no queue' do
      TestingJob.perform_async(1, 2)

      expect(TestingJob.calls).to eq([[1, 2]])
      expect(Cogworker.config.redis { |c| c.llen('cogworker:queue:default') }).to eq(0)
    end

    it 'ignores perform_in/perform_at delay and runs immediately' do
      TestingJob.perform_in(3600, 'x')
      expect(TestingJob.calls).to eq([['x']])
    end

    it 'propagates a raised error straight to the caller' do
      stub_const('BoomingTestingJob', Class.new do
        include Cogworker::Worker
        def perform = raise('kaboom')
      end)

      expect { BoomingTestingJob.perform_async }.to raise_error(RuntimeError, 'kaboom')
    end

    it 'still runs the configured server middleware chain' do
      seen = []
      middleware = Class.new do
        define_method(:call) do |_worker, job, _queue, &block|
          seen << job['class']
          block.call
        end
      end
      Cogworker.config.server_middleware { |chain| chain.add(middleware) }

      TestingJob.perform_async

      expect(seen).to eq(['TestingJob'])
    end
  end

  describe 'mode switches scoped to a block' do
    it 'restores the previous mode after the block' do
      described_class.fake!
      described_class.inline! { expect(described_class).to be_inline }
      expect(described_class).to be_fake
    end
  end
end
