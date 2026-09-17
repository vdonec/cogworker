# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Cogworker::Periodic::ReleaseMiddleware do
  subject(:middleware) { described_class.new }

  def running_key(pjid) = "periodic:running:#{pjid}"

  it 'is a no-op for a job without a periodic_pjid' do
    ran = false
    expect { middleware.call(nil, { 'class' => 'X' }, 'default') { ran = true } }.not_to raise_error
    expect(ran).to be(true)
  end

  it 'releases the running lock on success' do
    Cogworker.config.redis { |c| c.set(running_key('p1'), 'jid1') }
    job = { 'periodic_pjid' => 'p1' }

    middleware.call(nil, job, 'default') {}

    expect(Cogworker.config.redis { |c| c.get(running_key('p1')) }).to be_nil
  end

  it 'leaves the lock in place when a failed attempt still has retries left' do
    Cogworker.config.redis { |c| c.set(running_key('p2'), 'jid2') }
    job = { 'periodic_pjid' => 'p2', 'retry' => 3, 'retry_count' => 1 }

    expect do
      middleware.call(nil, job, 'default') { raise 'boom' }
    end.to raise_error('boom')

    expect(Cogworker.config.redis { |c| c.get(running_key('p2')) }).to eq('jid2')
  end

  it 'releases the lock when a failed attempt is the terminal one' do
    Cogworker.config.redis { |c| c.set(running_key('p3'), 'jid3') }
    job = { 'periodic_pjid' => 'p3', 'retry' => 0, 'retry_count' => 0 }

    expect do
      middleware.call(nil, job, 'default') { raise 'boom' }
    end.to raise_error('boom')

    expect(Cogworker.config.redis { |c| c.get(running_key('p3')) }).to be_nil
  end
end
