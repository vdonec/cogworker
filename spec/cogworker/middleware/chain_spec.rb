# frozen_string_literal: true

require 'cogworker'

RSpec.describe Cogworker::Middleware::Chain do
  def tagging_middleware(trace, tag)
    Class.new do
      define_method(:initialize) {}
      define_method(:call) do |_worker, _job, _queue, &block|
        trace << "before:#{tag}"
        block.call
        trace << "after:#{tag}"
      end
    end
  end

  it 'invokes entries in registration order, each wrapping the next' do
    chain = described_class.new
    trace = []

    chain.add(tagging_middleware(trace, 'a'))
    chain.add(tagging_middleware(trace, 'b'))

    chain.invoke('Worker', { 'a' => 1 }, 'default') { trace << 'perform' }

    expect(trace).to eq(%w[before:a before:b perform after:b after:a])
  end

  it 'replaces an existing entry of the same class rather than duplicating it' do
    chain = described_class.new
    logger = Class.new { def call(*, &block) = block.call }

    chain.add(logger)
    chain.add(logger)

    expect(chain.count).to eq(1)
  end

  it 'builds a fresh instance of each middleware on every invoke' do
    chain = described_class.new
    instances = []

    counting = Class.new do
      define_method(:initialize) { instances << self }
      define_method(:call) { |*, &block| block.call }
    end

    chain.add(counting)
    chain.invoke('W', {}, 'default') {}
    chain.invoke('W', {}, 'default') {}

    expect(instances.size).to eq(2)
    expect(instances[0]).not_to equal(instances[1])
  end

  it 'supports the 4-arg client middleware signature' do
    chain = described_class.new
    seen = nil

    client_mw = Class.new do
      define_method(:call) do |worker_class, job, queue, redis_pool, &block|
        seen = [worker_class, job, queue, redis_pool]
        block.call
      end
    end

    chain.add(client_mw)
    chain.invoke('MyWorker', { 'jid' => 'x' }, 'default', :pool) {}

    expect(seen).to eq(['MyWorker', { 'jid' => 'x' }, 'default', :pool])
  end
end
