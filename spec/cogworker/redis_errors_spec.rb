# frozen_string_literal: true

require 'spec_helper'
require 'stringio'

RSpec.describe Cogworker::RedisErrors do
  let(:log) { StringIO.new }

  before { allow(Cogworker).to receive(:logger).and_return(Cogworker::Logging.default_logger(log)) }

  it 'counts failover replies as Redis being unavailable, not just lost connections' do
    expect(described_class.unavailable?(Redis::CannotConnectError.new('x'))).to be(true)
    if defined?(RedisClient) # (redis-rb 5 only)
      expect(described_class.unavailable?(RedisClient::ConnectionError.new('EOFError'))).to be(true)
    end
    %w[READONLY LOADING MASTERDOWN TRYAGAIN BUSY].each do |code|
      expect(described_class.unavailable?(Redis::CommandError.new("#{code} something"))).to be(true)
    end
    expect(described_class.unavailable?(Redis::CommandError.new('WRONGTYPE Operation'))).to be(false)
    expect(described_class.unavailable?(Redis::CommandError.new('BUSYKEY Target key name already exists'))).to be(false)
    busygroup = Redis::CommandError.new('BUSYGROUP Consumer Group name already exists')
    expect(described_class.unavailable?(busygroup)).to be(false)
    wrapped = "ERR Error running script (call to f_1): @user_script:1: @user_script: 1: -READONLY You can't write"
    expect(described_class.unavailable?(Redis::CommandError.new(wrapped))).to be(true)
    expect(described_class.unavailable?(ArgumentError.new('x'))).to be(false)
  end

  it 'logs an outage once, summarizes repeats at most every SUMMARY_INTERVAL, and logs the recovery' do
    error = Redis::CannotConnectError.new('gone')
    100.times { described_class.report('Processor', error) }
    expect(log.string.lines.size).to eq(1)

    outage = described_class.instance_variable_get(:@outages)['Processor']
    outage[:summarized_at] -= described_class::SUMMARY_INTERVAL
    described_class.report('Processor', error)
    expect(log.string).to include('100 more error(s)')

    described_class.recovered('Processor')
    described_class.recovered('Processor') # nothing to end: no line
    expect(log.string.lines.size).to eq(3)
    expect(log.string).to include('Redis available again after 101 error(s)')
  end

  it 'logs every other error in full, every time' do
    3.times { described_class.report('Ticker', Redis::CommandError.new('WRONGTYPE x')) }

    expect(log.string.lines.size).to eq(3)
  end

  it 'reports recovery from a BestEffort site once its write goes through again' do
    Cogworker::BestEffort.call('Status') { raise Redis::CannotConnectError, 'gone' }
    Cogworker::BestEffort.call('Status') { :ok }

    expect(log.string).to include('Status: Redis available again')
  end
end
