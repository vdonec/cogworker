# frozen_string_literal: true

require 'spec_helper'
require 'stringio'

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
    job = { 'periodic_pjid' => 'p1', 'jid' => 'jid1' }

    middleware.call(nil, job, 'default') {}

    expect(Cogworker.config.redis { |c| c.get(running_key('p1')) }).to be_nil
  end

  it 'leaves the lock in place when a failed attempt still has retries left' do
    Cogworker.config.redis { |c| c.set(running_key('p2'), 'jid2') }
    job = { 'periodic_pjid' => 'p2', 'jid' => 'jid2', 'retry' => 3, 'retry_count' => 1 }

    expect do
      middleware.call(nil, job, 'default') { raise 'boom' }
    end.to raise_error('boom')

    expect(Cogworker.config.redis { |c| c.get(running_key('p2')) }).to eq('jid2')
  end

  it 'releases the lock when a failed attempt is the terminal one' do
    Cogworker.config.redis { |c| c.set(running_key('p3'), 'jid3') }
    job = { 'periodic_pjid' => 'p3', 'jid' => 'jid3', 'retry' => 0, 'retry_count' => 0 }

    expect do
      middleware.call(nil, job, 'default') { raise 'boom' }
    end.to raise_error('boom')

    expect(Cogworker.config.redis { |c| c.get(running_key('p3')) }).to be_nil
  end

  it 'shortens the lock to active_ttl while the run is in progress' do
    Cogworker.config.redis { |c| c.set(running_key('p4'), 'jid4', ex: 86_400) }
    ttl_during_run = nil

    middleware.call(nil, { 'periodic_pjid' => 'p4', 'jid' => 'jid4' }, 'default') do
      ttl_during_run = Cogworker.config.redis { |c| c.ttl(running_key('p4')) }
    end

    expect(ttl_during_run).to be_between(1, Cogworker::Periodic::RunningLock.active_ttl)
  end

  it "never releases or re-times a lock owned by a different jid (a newer run's)" do
    Cogworker.config.redis { |c| c.set(running_key('p6'), 'newer', ex: 86_400) }

    middleware.call(nil, { 'periodic_pjid' => 'p6', 'jid' => 'older' }, 'default') {}

    expect(Cogworker.config.redis { |c| c.get(running_key('p6')) }).to eq('newer')
    expect(Cogworker.config.redis { |c| c.ttl(running_key('p6')) })
      .to be > Cogworker::Periodic::RunningLock.active_ttl
  end

  it 'still runs the job when shortening the lock fails (best-effort; the heartbeat shortens it later)' do
    allow(Cogworker::Periodic::RunningLock).to receive(:touch).and_raise(Redis::CannotConnectError, 'blip')
    allow(Cogworker).to receive(:logger).and_return(Cogworker::Logging.default_logger(StringIO.new))
    ran = false

    middleware.call(nil, { 'periodic_pjid' => 'p7', 'jid' => 'jid7' }, 'default') { ran = true }

    expect(ran).to be(true)
  end

  it "releases the running lock when the job's cogworker_retry_in kills it, though retries were left" do
    stub_const('KilledPeriodicJob', Class.new do
      include Cogworker::Worker
      cogworker_retry_in { |*| :kill }

      def perform(*)
        raise 'permanent'
      end
    end)
    allow(Cogworker).to receive(:logger).and_return(Cogworker::Logging.default_logger(StringIO.new))
    jid = Cogworker::Client.push('class' => 'KilledPeriodicJob', 'args' => [], 'retry' => 10,
                                 'periodic_pjid' => 'pk')
    Cogworker.config.redis { |c| c.set(running_key('pk'), jid) }

    Cogworker::Processor.new(Cogworker::Manager.new).send(:process_one)

    expect(Cogworker.config.redis { |c| [c.get(running_key('pk')), c.zcard('cogworker:dead')] }).to eq([nil, 1])
  end
end
