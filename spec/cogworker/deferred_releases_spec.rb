# frozen_string_literal: true

require 'spec_helper'
require 'stringio'

RSpec.describe Cogworker::DeferredReleases do
  let(:manager) { Cogworker::Manager.new }

  before { allow(Cogworker).to receive(:logger).and_return(Cogworker::Logging.default_logger(StringIO.new)) }

  it 'retries a cron lock release that failed when the job finished, on the next heartbeat — not after its TTL' do
    Cogworker.config.redis { |c| c.set('periodic:running:pj1', 'j1', ex: 420) }
    allow(Cogworker::Periodic::RunningLock).to receive(:release).and_raise(Redis::CommandError, 'READONLY no writes')

    ran = false
    Cogworker::Periodic::ReleaseMiddleware.new.call(nil, { 'periodic_pjid' => 'pj1', 'jid' => 'j1' }, 'default') do
      ran = true
    end
    expect(ran).to be(true)
    expect(described_class.pending).to eq('periodic:running:pj1' => 'j1')

    allow(Cogworker::Periodic::RunningLock).to receive(:release).and_call_original
    Cogworker::Heartbeat.new(manager).send(:beat)

    expect(Cogworker.config.redis { |c| c.get('periodic:running:pj1') }).to be_nil
    expect(described_class.pending).to be_empty
  end

  it 'retries a failed unique-lock release too, and never releases a lock that changed hands meanwhile' do
    job = { 'jid' => 'u1', 'class' => 'X', 'queue' => 'default', 'args' => [], 'unique' => 'until_executed' }
    key = "cogworker:unique:#{Cogworker::UniqueJobs.digest(job)}"
    allow(Cogworker::OwnedKey).to receive(:delete).and_raise(Redis::CannotConnectError, 'gone')
    Cogworker::UniqueJobs::ReleaseMiddleware.new.call(nil, job, 'default') {}
    allow(Cogworker::OwnedKey).to receive(:delete).and_call_original
    expect(described_class.pending.keys).to eq([key])

    Cogworker.config.redis { |c| c.set(key, 'someone-else') }
    Cogworker::Heartbeat.new(manager).send(:beat)

    expect(Cogworker.config.redis { |c| c.get(key) }).to eq('someone-else')
    expect(described_class.pending).to be_empty
  end

  it 'drops a release that fails for a reason other than Redis being away (the key of the wrong type)' do
    Cogworker.config.redis { |c| c.rpush('cogworker:unique:x', 'a list') }
    described_class.add('cogworker:unique:x', 'j')

    Cogworker.config.redis { |c| described_class.retry_all(c) }

    expect(described_class.pending).to be_empty
  end

  it "doesn't count a beat as failed when only the deferred releases hit Redis being away" do
    described_class.add('periodic:running:p', 'j')
    allow(described_class).to receive(:retry_all).and_raise(Redis::CannotConnectError, 'gone')
    heartbeat = Cogworker::Heartbeat.new(manager)

    expect(heartbeat.send(:beat_safely)).to be(true)
    expect(heartbeat.instance_variable_get(:@beat_failed)).to be(false)
  end

  it 'gets one last try when the process stops' do
    Cogworker.config.redis { |c| c.set('periodic:running:p2', 'j2') }
    described_class.add('periodic:running:p2', 'j2')
    launcher = Cogworker::Launcher.new
    %i[@manager @scheduled @ticker @heartbeat].each do |ivar|
      allow(launcher.instance_variable_get(ivar)).to receive(:stop!)
    end

    launcher.stop!

    expect(Cogworker.config.redis { |c| c.get('periodic:running:p2') }).to be_nil
  end
end
