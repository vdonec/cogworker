# frozen_string_literal: true

require 'spec_helper'
require 'json'

RSpec.describe 'Manager + Processor end-to-end execution' do
  after do
    @manager&.stop!(timeout: 2)
  end

  it 'runs a pushed job through the full server middleware chain and updates stats' do
    executed = Queue.new
    trace = []

    tagging_middleware = Class.new do
      define_method(:call) do |_worker, job, _queue, &block|
        trace << job['class']
        block.call
      end
    end
    Cogworker.config.server_middleware { |chain| chain.add(tagging_middleware) }

    stub_const('EchoJob', Class.new do
      include Cogworker::Worker
    end)
    EchoJob.define_method(:perform) { |*args| executed << args }

    EchoJob.perform_async(1, 'two')

    @manager = Cogworker::Manager.new
    @manager.start!

    result = wait_for do
      executed.pop(true)
    rescue StandardError
      nil
    end
    expect(result).to eq([1, 'two'])
    expect(trace).to eq(['EchoJob'])

    expect(Cogworker::Stats.new.processed).to eq(1)
    expect(Cogworker::Stats.new.failed).to eq(0)
  end

  it 'routes a failing job with retry: false straight to the dead set' do
    stub_const('BoomJob', Class.new do
      include Cogworker::Worker
      cogworker_options retry: false

      def perform(*)
        raise 'kaboom'
      end
    end)

    BoomJob.perform_async

    @manager = Cogworker::Manager.new
    @manager.start!

    wait_for { Cogworker::Stats.new.dead_size == 1 }
    expect(Cogworker::Stats.new.retry_size).to eq(0)
    expect(Cogworker::Stats.new.failed).to eq(1)
  end

  it 'routes a failing job with retries remaining to the retry set with error info' do
    stub_const('FlakyJob', Class.new do
      include Cogworker::Worker
      cogworker_options retry: 3

      def perform(*)
        raise ArgumentError, 'nope'
      end
    end)

    FlakyJob.perform_async

    @manager = Cogworker::Manager.new
    @manager.start!

    wait_for { Cogworker::Stats.new.retry_size == 1 }
    raw = Cogworker.config.redis { |c| c.zrange('cogworker:retry', 0, 0) }.first
    job = JSON.parse(raw)
    expect(job['error_class']).to eq('ArgumentError')
    expect(job['retry_count']).to eq(1)
  end

  it 'runs a job whose class was never defined through the same middleware chain as any other ' \
     'failure — History/Status must see it too, not just retry/dead routing' do
    Cogworker::History.configure_server_middleware(Cogworker.config, max_entries: 100)
    Cogworker::Status.configure_server_middleware(Cogworker.config, expiration: 60)

    # Pushed directly (not via `.perform_async`, which needs a real class to
    # call it on) — this is exactly the shape a `retry`/`retry_now` button
    # click produces for an entry whose class no longer exists.
    raw = JSON.generate('jid' => 'ghostjid', 'class' => 'TotallyUndefinedGhostJob', 'args' => [],
                        'queue' => 'default', 'retry' => 0)
    Cogworker.config.redis do |c|
      c.sadd('cogworker:queues', 'default')
      c.lpush('cogworker:queue:default', raw)
    end

    @manager = Cogworker::Manager.new
    @manager.start!

    wait_for { Cogworker::Stats.new.dead_size == 1 } # unaffected: still routes to dead as before

    entries, = Cogworker::History::Storage.page('failed', 1, 10)
    entry = entries.find { |e| e['jid'] == 'ghostjid' }
    expect(entry).not_to be_nil, 'expected the History entry for the unresolvable class to exist'
    expect(entry['error_class']).to eq('NameError')

    expect(Cogworker::Status.status('ghostjid')).to eq('failed')
  end

  it "a job with retry: false (the literal boolean, not 0) doesn't crash Status middleware — " \
     "JobUtil.max_retries handles false/true/nil/Integer explicitly, never job['retry'].to_i " \
     'directly (FalseClass has no #to_i)' do
    Cogworker::Status.configure_server_middleware(Cogworker.config, expiration: 60)

    stub_const('BoomOnceJob', Class.new do
      include Cogworker::Worker
      cogworker_options retry: false

      def perform(*)
        raise 'kaboom'
      end
    end)

    BoomOnceJob.perform_async

    @manager = Cogworker::Manager.new
    @manager.start!

    wait_for { Cogworker::Stats.new.dead_size == 1 }
    jid = Cogworker.config.redis { |c| c.zrange('cogworker:dead', 0, 0) }.first
                   .then { |raw| JSON.parse(raw)['jid'] }
    expect(Cogworker::Status.status(jid)).to eq('failed')
  end

  it 'registers and deregisters in-flight jobs in the WorkSet while running' do
    gate = Queue.new
    stub_const('SlowJob', Class.new do
      include Cogworker::Worker
      define_method(:perform) { gate.pop }
    end)

    SlowJob.perform_async

    @manager = Cogworker::Manager.new
    @manager.start!
    # WorkSet discovers in-flight jobs by first listing live processes from
    # ProcessSet, so a heartbeat beat has to exist for it to look under.
    Cogworker::Heartbeat.new(@manager).send(:beat)

    wait_for { Cogworker::WorkSet.new.size == 1 }
    work = Cogworker::WorkSet.new.to_a.first[2]
    expect(work.job['class']).to eq('SlowJob')
    expect(work.queue).to eq('default')

    gate << :go
    wait_for { Cogworker::WorkSet.new.size == 0 } # rubocop:disable Style/ZeroLengthPredicate -- WorkSet has no #empty? (Enumerable doesn't provide one)
  end
end
