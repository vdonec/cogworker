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

    it 'pause!/resume! toggle paused?, independently per queue name' do
      default_queue = described_class.new('default')
      low_queue = described_class.new('low')

      expect(default_queue.paused?).to be(false)

      default_queue.pause!
      expect(default_queue.paused?).to be(true)
      expect(low_queue.paused?).to be(false) # pausing one queue doesn't pause another

      default_queue.resume!
      expect(default_queue.paused?).to be(false)
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

    it "quiet!/resume! toggle a live process's Manager#quiet? via pub/sub — unlike stop!, this round-trips" do
      manager = Cogworker::Manager.new
      heartbeat = Cogworker::Heartbeat.new(manager)
      heartbeat.start!
      wait_for do
        Cogworker.config.redis { |c| c.pubsub('numsub', "cogworker:signal:#{Cogworker.identity}") }[1].to_i.positive?
      end

      process = wait_for { described_class.new.find { |p| p.identity == Cogworker.identity } }

      process.quiet!
      wait_for { manager.quiet? }

      process.resume!
      wait_for { !manager.quiet? }
    ensure
      heartbeat&.stop!
    end
  end
end
