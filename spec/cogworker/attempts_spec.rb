# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Cogworker::Attempts do
  it 'records attempts oldest-first, with the given attempt number, outcome, and error class/message' do
    described_class.record('jid1', attempt: 1, error: RuntimeError.new('first'), outcome: 'retrying')
    described_class.record('jid1', attempt: 2, error: ArgumentError.new('second'), outcome: 'dead')

    attempts = described_class.for('jid1')
    expect(attempts.size).to eq(2)
    expect(attempts[0]).to include('attempt' => 1, 'outcome' => 'retrying', 'error_class' => 'RuntimeError',
                                   'error_message' => 'first')
    expect(attempts[1]).to include('attempt' => 2, 'outcome' => 'dead', 'error_class' => 'ArgumentError',
                                   'error_message' => 'second')
    expect(attempts[0]['failed_at']).to be_a(Float)
  end

  it 'returns an empty array for a jid with no recorded attempts' do
    expect(described_class.for('never-failed')).to eq([])
  end

  it 'trims to the last MAX_ENTRIES attempts, dropping the oldest first' do
    (described_class::MAX_ENTRIES + 5).times do |i|
      described_class.record('jid2', attempt: i + 1, error: RuntimeError.new("boom #{i}"), outcome: 'retrying')
    end

    attempts = described_class.for('jid2')
    expect(attempts.size).to eq(described_class::MAX_ENTRIES)
    expect(attempts.first['attempt']).to eq(6) # the first 5 were trimmed off
    expect(attempts.last['attempt']).to eq(described_class::MAX_ENTRIES + 5)
  end

  it 'sets a TTL on the attempt log so an abandoned dead entry does not grow forever' do
    described_class.record('jid3', attempt: 1, error: RuntimeError.new('boom'), outcome: 'dead')

    ttl = Cogworker.config.redis { |c| c.ttl(Cogworker::RedisKeys.job_attempts('jid3')) }
    expect(ttl).to be_between(1, described_class::TTL_SECONDS)
  end

  it '.clear removes the whole log — used when a Retrying/Dead entry is deleted (or all-deleted) via the Web UI' do
    described_class.record('jid4', attempt: 1, error: RuntimeError.new('boom'), outcome: 'retrying')
    expect(described_class.for('jid4')).not_to be_empty

    described_class.clear('jid4')

    expect(described_class.for('jid4')).to eq([])
  end
end
