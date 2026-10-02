# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Client.push unique: :until_executed integration' do
  before do
    stub_const('UniqueJob', Class.new do
      include Cogworker::Worker

      cogworker_options unique: :until_executed

      def perform(*); end
    end)
  end

  it 'only enqueues one of several identical pushes while the first is still queued' do
    jids = Array.new(4) { UniqueJob.perform_async(1) }

    expect(jids.compact.size).to eq(1)
    expect(Cogworker.config.redis { |c| c.llen('cogworker:queue:default') }).to eq(1)
  end

  it 'lets a different args payload through despite the class being unique' do
    first = UniqueJob.perform_async(1)
    second = UniqueJob.perform_async(2)

    expect([first, second]).to all(be_a(String))
    expect(Cogworker.config.redis { |c| c.llen('cogworker:queue:default') }).to eq(2)
  end

  it 'allows a new push again after the job has been executed (lock released)' do
    first = UniqueJob.perform_async(1)
    worker = UniqueJob.new
    job = JSON.parse(Cogworker.config.redis { |c| c.rpop('cogworker:queue:default') })

    Cogworker.config.server_chain.invoke(worker, job, 'default') { worker.perform(*job['args']) }

    second = UniqueJob.perform_async(1)

    expect(first).to be_a(String)
    expect(second).to be_a(String)
  end

  it 'plain jobs (no unique option) are never deduplicated' do
    stub_const('PlainJob', Class.new do
      include Cogworker::Worker

      def perform(*); end
    end)

    jids = Array.new(4) { PlainJob.perform_async }

    expect(jids.compact.size).to eq(4)
    expect(Cogworker.config.redis { |c| c.llen('cogworker:queue:default') }).to eq(4)
  end

  it 'counts the lock TTL from when a scheduled job is due, not from when it was pushed' do
    UniqueJob.perform_in(3 * 86_400, 1)

    key = Cogworker.config.redis { |c| c.keys('cogworker:unique:*') }.first
    expect(Cogworker.config.redis { |c| c.ttl(key) }).to be > (3 * 86_400)
  end

  it 'extends the lock over the retry backoff when an attempt fails and will be retried' do
    Cogworker.config.unique_lock_ttl = 100
    UniqueJob.define_method(:perform) { |*| raise 'boom' }
    jid = UniqueJob.perform_async(1)
    key = Cogworker.config.redis { |c| c.keys('cogworker:unique:*') }.first
    raw = Cogworker.config.redis { |c| c.rpop('cogworker:queue:default') }

    allow_any_instance_of(Cogworker::Processor).to receive(:retry_delay).and_return(10_000)
    work = Cogworker::BasicFetch::UnitOfWork.new('default', raw)
    Cogworker::Processor.new(Cogworker::Manager.new).send(:execute, work)

    expect(Cogworker.config.redis { |c| c.zcard('cogworker:retry') }).to eq(1)
    expect(Cogworker.config.redis { |c| c.get(key) }).to eq(jid)
    expect(Cogworker.config.redis { |c| c.ttl(key) }).to be > 10_000
  end
end
