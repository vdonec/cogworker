# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Introspection API' do
  describe Cogworker::Queue do
    it 'reports size, latency, and yields JobRecord wrappers' do
      stub_const('QJob', Class.new { include Cogworker::Worker })
      QJob.perform_async(1)

      queue = described_class.new('default')
      expect(queue.size).to eq(1)
      expect(queue.latency).to be >= 0

      record = queue.first
      expect(record&.klass).to eq('QJob')
      expect(record&.args).to eq([1])
      expect(record&.item&.[]('class')).to eq('QJob')
    end
  end

  describe Cogworker::ProcessSet do
    it 'reflects a live heartbeat and supports quiet!/stop! via pub/sub' do
      manager = Cogworker::Manager.new
      heartbeat = Cogworker::Heartbeat.new(manager)
      heartbeat.send(:beat)

      process = wait_for { described_class.new.find { |p| p.identity == Cogworker.identity } }
      expect(process['busy']).to eq(0)

      heartbeat.stop!
      expect(described_class.new.to_a).to be_empty
    end
  end
end
