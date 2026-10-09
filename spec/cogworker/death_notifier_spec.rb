# frozen_string_literal: true

require 'spec_helper'
require 'stringio'

RSpec.describe Cogworker::DeathNotifier do
  let(:log) { StringIO.new }
  let(:calls) { [] }
  let(:job) { { 'jid' => 'dn1', 'class' => 'DyingJob', 'args' => [1], 'error_class' => 'RuntimeError' } }
  let(:error) { RuntimeError.new('boom') }

  before do
    allow(Cogworker).to receive(:logger).and_return(Cogworker::Logging.default_logger(log))
    calls = self.calls
    stub_const('DyingJob', Class.new { include Cogworker::Worker })
    DyingJob.cogworker_retries_exhausted { |j, e| calls << [:class, j['jid'], e] }
  end

  it "runs the class's hook first, then every death handler in order" do
    Cogworker.config.death_handlers << ->(j, e) { calls << [:first, j['jid'], e] }
    Cogworker.config.death_handlers << ->(j, e) { calls << [:second, j['jid'], e] }

    described_class.notify(job, error)

    expect(calls).to eq([[:class, 'dn1', error], [:first, 'dn1', error], [:second, 'dn1', error]])
  end

  it 'isolates a hook that raises: logged, and the rest still run' do
    DyingJob.cogworker_retries_exhausted { |_j, _e| raise 'hook broke' }
    Cogworker.config.death_handlers << ->(_j, _e) { raise ArgumentError, 'handler broke' }
    Cogworker.config.death_handlers << ->(j, _e) { calls << j['jid'] }

    expect { described_class.notify(job, error) }.not_to raise_error

    expect(calls).to eq(['dn1'])
    expect(log.string).to include('cogworker_retries_exhausted failed for jid=dn1', 'hook broke',
                                  'death handler failed for jid=dn1', 'handler broke')
  end

  it 'hands each hook its own copy: changes never reach the caller or the next hook' do
    DyingJob.cogworker_retries_exhausted do |j, _e|
      j['args'] << 2
      j['jid'] = 'changed'
    end
    Cogworker.config.death_handlers << ->(j, _e) { calls << j.dup }

    described_class.notify(job, error)

    expect(job).to eq('jid' => 'dn1', 'class' => 'DyingJob', 'args' => [1], 'error_class' => 'RuntimeError')
    expect(calls).to eq([job])
  end

  it 'runs only the death handlers for a class that no longer exists' do
    Cogworker.config.death_handlers << ->(j, _e) { calls << [:handler, j['class']] }

    described_class.notify(job.merge('class' => 'GoneJob'), error)

    expect(calls).to eq([[:handler, 'GoneJob']])
  end

  it 'passes a lambda only the arguments it takes' do
    Cogworker.config.death_handlers << ->(j) { calls << j['jid'] }

    described_class.notify(job, error)

    expect(calls.last).to eq('dn1')
  end

  it 'gives a record filed later a JobFailedError with the original message' do
    Cogworker.config.death_handlers << ->(j, e) { calls << [j['error_class'], e.class, e.message] }

    described_class.notify_failed(JSON.generate(job.merge('error_message' => 'original')))

    expect(calls.last).to eq(['RuntimeError', Cogworker::JobFailedError, 'original'])
  end
end
