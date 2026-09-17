# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Cogworker::History' do
  before { Cogworker::History.max_entries = Cogworker::History::DEFAULT_MAX_ENTRIES }

  describe Cogworker::History::Middleware do
    before { Cogworker.config.server_middleware { |chain| chain.add(described_class) } }

    it 'records a full entry (class, queue, args, timing) for a successful run' do
      stub_const('HistorySuccessJob', Class.new do
        include Cogworker::Worker
        def perform(*); end
      end)
      HistorySuccessJob.perform_async(1, 'two', { 'three' => 3 })

      manager = Cogworker::Manager.new
      manager.start!
      wait_for { Cogworker::History::Storage.page('all', 1, 10).last == 1 }
      manager.stop!(timeout: 2)

      entries, total = Cogworker::History::Storage.page('all', 1, 10)
      expect(total).to eq(1)
      entry = entries.first
      expect(entry['class']).to eq('HistorySuccessJob')
      expect(entry['queue']).to eq('default')
      expect(entry['args']).to eq([1, 'two', { 'three' => 3 }])
      expect(entry['status']).to eq('success')
      expect(entry['finished_at']).to be >= entry['started_at']
      expect(entry).not_to have_key('backtrace')
    end

    it 'records the error class/message/backtrace for a failing run, and still routes it to retry/dead' do
      stub_const('HistoryFailJob', Class.new do
        include Cogworker::Worker
        cogworker_options retry: false

        def perform(*)
          raise ArgumentError, 'boom'
        end
      end)
      HistoryFailJob.perform_async

      manager = Cogworker::Manager.new
      manager.start!
      wait_for { Cogworker::History::Storage.page('failed', 1, 10).last == 1 }
      manager.stop!(timeout: 2)

      entries, = Cogworker::History::Storage.page('failed', 1, 10)
      entry = entries.first
      expect(entry['status']).to eq('failed')
      expect(entry['error_class']).to eq('ArgumentError')
      expect(entry['error_message']).to eq('boom')
      expect(entry['backtrace']).to be_an(Array)
      expect(entry['backtrace']).not_to be_empty

      # the History middleware re-raises — the job still ends up dead (retry: false)
      expect(Cogworker::Stats.new.dead_size).to eq(1)
    end

    it 'keeps success and failure in separate lists, both reachable via "all"' do
      stub_const('HistoryOkJob', Class.new do
        include Cogworker::Worker
        def perform(*); end
      end)
      stub_const('HistoryBadJob', Class.new do
        include Cogworker::Worker
        cogworker_options retry: false
        def perform(*) = raise('nope')
      end)
      HistoryOkJob.perform_async
      HistoryBadJob.perform_async

      manager = Cogworker::Manager.new
      manager.start!
      wait_for { Cogworker::History::Storage.page('all', 1, 10).last == 2 }
      manager.stop!(timeout: 2)

      expect(Cogworker::History::Storage.page('success', 1, 10).last).to eq(1)
      expect(Cogworker::History::Storage.page('failed', 1, 10).last).to eq(1)
      expect(Cogworker::History::Storage.page('all', 1, 10).last).to eq(2)
    end
  end

  describe Cogworker::History::Storage do
    it 'paginates newest-first' do
      3.times do |i|
        described_class.record({ 'jid' => "j#{i}", 'class' => 'X', 'args' => [] }, 'default', i, i + 1, 'success')
      end

      page1, total = described_class.page('all', 1, 2)
      expect(total).to eq(3)
      expect(page1.map { |e| e['jid'] }).to eq(%w[j2 j1])

      page2, = described_class.page('all', 2, 2)
      expect(page2.map { |e| e['jid'] }).to eq(%w[j0])
    end

    it 'trims each list independently to History.max_entries, oldest first' do
      Cogworker::History.max_entries = 3
      5.times do |i|
        described_class.record({ 'jid' => "j#{i}", 'class' => 'X', 'args' => [] }, 'default', i, i + 1, 'success')
      end

      _entries, total = described_class.page('all', 1, 10)
      expect(total).to eq(3)
      entries, = described_class.page('all', 1, 10)
      expect(entries.map { |e| e['jid'] }).to eq(%w[j4 j3 j2]) # the 2 oldest (j0, j1) were trimmed
    end

    describe '.daily_counts' do
      it 'buckets success/failed entries by UTC calendar day' do
        today = Time.now.utc
        yesterday = today - 86_400

        described_class.record({ 'jid' => 'ok1', 'class' => 'X', 'args' => [] }, 'default', 0, today.to_f, 'success')
        described_class.record({ 'jid' => 'ok2', 'class' => 'X', 'args' => [] }, 'default', 0, today.to_f, 'success')
        described_class.record({ 'jid' => 'bad1', 'class' => 'X', 'args' => [] }, 'default', 0, today.to_f, 'failed')
        described_class.record({ 'jid' => 'ok3', 'class' => 'X', 'args' => [] }, 'default', 0, yesterday.to_f,
                               'success')

        counts = described_class.daily_counts(14)

        expect(counts[today.strftime('%Y-%m-%d')]).to eq('success' => 2, 'failed' => 1)
        expect(counts[yesterday.strftime('%Y-%m-%d')]).to eq('success' => 1, 'failed' => 0)
      end

      it 'excludes entries older than the requested window' do
        old = Time.now.utc - (20 * 86_400)
        described_class.record({ 'jid' => 'old1', 'class' => 'X', 'args' => [] }, 'default', 0, old.to_f, 'success')

        counts = described_class.daily_counts(14)

        expect(counts[old.strftime('%Y-%m-%d')]).to be_nil
      end
    end
  end

  describe 'Cogworker::History.configure_server_middleware' do
    it 'adds the middleware to the server chain and applies max_entries' do
      Cogworker::History.configure_server_middleware(Cogworker.config, max_entries: 42)
      expect(Cogworker::History.max_entries).to eq(42)
      expect(Cogworker.config.server_chain.map(&:klass)).to include(Cogworker::History::Middleware)
    end
  end
end
