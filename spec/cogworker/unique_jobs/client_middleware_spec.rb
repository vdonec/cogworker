# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Cogworker::UniqueJobs::ClientMiddleware do
  subject(:middleware) { described_class.new }

  def lock_key(job) = "cogworker:unique:#{Cogworker::UniqueJobs.digest(job)}"

  it 'is a no-op (always yields) for a job without unique: :until_executed' do
    job = { 'class' => 'X', 'queue' => 'default', 'args' => [], 'jid' => 'j1' }
    ran = false

    middleware.call(nil, job, 'default', Cogworker.config.redis_pool) { ran = true }

    expect(ran).to be(true)
    expect(Cogworker.config.redis { |c| c.get(lock_key(job)) }).to be_nil
  end

  it 'claims the lock and yields for the first push of a unique job' do
    job = { 'class' => 'X', 'queue' => 'default', 'args' => [], 'jid' => 'j1', 'unique' => 'until_executed' }
    ran = false

    middleware.call(nil, job, 'default', Cogworker.config.redis_pool) { ran = true }

    expect(ran).to be(true)
    expect(Cogworker.config.redis { |c| c.get(lock_key(job)) }).to eq('j1')
    expect(job['unique_skipped']).to be_nil
  end

  it 'skips (does not yield) a duplicate push while the lock is held' do
    Cogworker.config.redis { |c| c.set('cogworker:unique:existing', 'other-jid') }
    job = { 'class' => 'X', 'queue' => 'default', 'args' => [], 'jid' => 'j2', 'unique' => 'until_executed' }
    allow(Cogworker::UniqueJobs).to receive(:digest).with(job).and_return('existing')
    ran = false

    middleware.call(nil, job, 'default', Cogworker.config.redis_pool) { ran = true }

    expect(ran).to be(false)
    expect(job['unique_skipped']).to be(true)
    expect(Cogworker.config.redis { |c| c.get('cogworker:unique:existing') }).to eq('other-jid')
  end
end
