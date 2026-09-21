# frozen_string_literal: true

require 'spec_helper'
require 'json'

RSpec.describe Cogworker::BasicFetch do
  it 'pops work off an unpaused queue' do
    Cogworker.config.redis { |c| c.lpush('cogworker:queue:default', JSON.generate('jid' => 'x')) }

    fetch = described_class.new(%w[default])
    work = fetch.retrieve_work

    expect(work.queue).to eq('default')
    expect(JSON.parse(work.raw_job)['jid']).to eq('x')
  end

  it "never pops from a paused queue, even though the job is still sitting there — pausing stops " \
     "delivery, it doesn't touch what's already enqueued" do
    Cogworker.config.redis { |c| c.lpush('cogworker:queue:default', JSON.generate('jid' => 'paused-job')) }
    Cogworker::Queue.new('default').pause!

    fetch = described_class.new(%w[default])
    work = fetch.retrieve_work

    expect(work).to be_nil
    expect(Cogworker.config.redis { |c| c.llen('cogworker:queue:default') }).to eq(1) # still there, untouched
  end

  it 'only skips the paused queue — an unpaused sibling queue still gets fetched from normally' do
    Cogworker.config.redis { |c| c.lpush('cogworker:queue:low', JSON.generate('jid' => 'low-job')) }
    Cogworker::Queue.new('default').pause!

    fetch = described_class.new(%w[default low])
    work = fetch.retrieve_work

    expect(work.queue).to eq('low')
  end

  it "picks a job right back up the moment it's resumed — pause state is read fresh every " \
     'retrieve_work call, never cached from when BasicFetch was constructed' do
    queue = Cogworker::Queue.new('default')
    queue.pause!
    Cogworker.config.redis { |c| c.lpush('cogworker:queue:default', JSON.generate('jid' => 'resumed-job')) }

    fetch = described_class.new(%w[default])
    expect(fetch.retrieve_work).to be_nil

    queue.resume!
    work = fetch.retrieve_work
    expect(JSON.parse(work.raw_job)['jid']).to eq('resumed-job')
  end

  it "doesn't hang on BRPOP with an empty key list when every one of its queues is paused — sleeps out " \
     'one TIMEOUT and returns nil instead, same as a real empty-queue BRPOP timeout would' do
    stub_const('Cogworker::BasicFetch::TIMEOUT', 0.05) # keep the spec fast without changing the behavior under test
    Cogworker::Queue.new('default').pause!
    fetch = described_class.new(%w[default])

    started = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
    result = fetch.retrieve_work
    elapsed = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC) - started

    expect(result).to be_nil
    expect(elapsed).to be >= 0.05
  end
end
