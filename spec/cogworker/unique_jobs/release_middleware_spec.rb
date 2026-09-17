# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Cogworker::UniqueJobs::ReleaseMiddleware do
  subject(:middleware) { described_class.new }

  def lock_key(job) = "cogworker:unique:#{Cogworker::UniqueJobs.digest(job)}"

  let(:job) { { 'class' => 'X', 'queue' => 'default', 'args' => [], 'unique' => 'until_executed' } }

  it 'is a no-op for a job without unique: :until_executed' do
    plain = { 'class' => 'X', 'queue' => 'default', 'args' => [] }
    ran = false

    expect { middleware.call(nil, plain, 'default') { ran = true } }.not_to raise_error
    expect(ran).to be(true)
  end

  it 'releases the lock on success' do
    Cogworker.config.redis { |c| c.set(lock_key(job), 'jid1') }

    middleware.call(nil, job, 'default') {}

    expect(Cogworker.config.redis { |c| c.get(lock_key(job)) }).to be_nil
  end

  it 'leaves the lock in place when a failed attempt still has retries left' do
    retryable = job.merge('retry' => 3, 'retry_count' => 1)
    Cogworker.config.redis { |c| c.set(lock_key(retryable), 'jid2') }

    expect do
      middleware.call(nil, retryable, 'default') { raise 'boom' }
    end.to raise_error('boom')

    expect(Cogworker.config.redis { |c| c.get(lock_key(retryable)) }).to eq('jid2')
  end

  it 'releases the lock when a failed attempt is the terminal one' do
    terminal = job.merge('retry' => 0, 'retry_count' => 0)
    Cogworker.config.redis { |c| c.set(lock_key(terminal), 'jid3') }

    expect do
      middleware.call(nil, terminal, 'default') { raise 'boom' }
    end.to raise_error('boom')

    expect(Cogworker.config.redis { |c| c.get(lock_key(terminal)) }).to be_nil
  end
end
