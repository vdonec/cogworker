# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Cogworker::Status' do
  before do
    Cogworker::Status.configure_client_middleware(Cogworker.config, expiration: 60)
    Cogworker::Status.configure_server_middleware(Cogworker.config, expiration: 60)
  end

  it 'marks a job queued on push' do
    stub_const('StatusJob', Class.new do
      include Cogworker::Worker
      include Cogworker::Status::Worker
      def perform(*); end
    end)

    jid = StatusJob.perform_async

    expect(Cogworker::Status.status(jid)).to eq('queued')
    expect(Cogworker.config.redis { |c| c.ttl("status:#{jid}") }).to be > 0
  end

  it 'goes working -> complete for a successful job' do
    gate = Queue.new
    stub_const('SlowStatusJob', Class.new do
      include Cogworker::Worker
      include Cogworker::Status::Worker
      define_method(:perform) { gate.pop }
    end)

    jid = SlowStatusJob.perform_async
    manager = Cogworker::Manager.new
    manager.start!

    wait_for { Cogworker::Status.status(jid) == 'working' }
    gate << :go
    wait_for { Cogworker::Status.status(jid) == 'complete' }

    manager.stop!(timeout: 2)
  end

  it 'goes to retrying (not failed) while retries remain, then failed once exhausted' do
    stub_const('FlakyStatusJob', Class.new do
      include Cogworker::Worker
      include Cogworker::Status::Worker
      cogworker_options retry: 1
      def perform(*)
        raise 'nope'
      end
    end)

    jid = FlakyStatusJob.perform_async
    manager = Cogworker::Manager.new
    manager.start!

    wait_for { Cogworker::Status.status(jid) == 'retrying' }
    info = Cogworker::Status.get(jid)
    expect(info['error_class']).to eq('RuntimeError')

    # graduate the retry back into the queue immediately for the test
    raw = Cogworker.config.redis { |c| c.zrange('cogworker:retry', 0, 0) }.first
    Cogworker.config.redis do |c|
      c.zrem('cogworker:retry', raw)
      c.lpush('cogworker:queue:default', raw)
    end

    wait_for { Cogworker::Status.status(jid) == 'failed' }

    manager.stop!(timeout: 2)
  end

  describe Cogworker::Status::Worker do
    it '#at and #store write custom fields readable via Status.get' do
      stub_const('ProgressJob', Class.new do
        include Cogworker::Worker
        include Cogworker::Status::Worker
      end)
      job = ProgressJob.new
      job.jid = 'manual-jid'

      job.at(42, 'halfway')
      info = Cogworker::Status.get('manual-jid')
      expect(info['pct']).to eq('42')
      expect(info['message']).to eq('halfway')

      job.store('custom' => 'value')
      expect(Cogworker::Status.get('manual-jid')['custom']).to eq('value')
    end
  end
end
