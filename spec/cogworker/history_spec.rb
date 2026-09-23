# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Cogworker::History' do
  before do
    Cogworker::History.retention_days = Cogworker::History::DEFAULT_RETENTION_DAYS
    Cogworker::History.max_entries = Cogworker::History::DEFAULT_MAX_ENTRIES
    Cogworker::History.daily_stats_retention_days = Cogworker::History::DEFAULT_DAILY_STATS_RETENTION_DAYS
  end

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

      entries, total = Cogworker::History::Storage.page('all', 1, 10)
      expect(total).to eq(1)
      entry = entries.first
      expect(entry['class']).to eq('HistorySuccessJob')
      expect(entry['queue']).to eq('default')
      expect(entry['args']).to eq([1, 'two', { 'three' => 3 }])
      expect(entry['status']).to eq('success')
      expect(entry['finished_at']).to be >= entry['started_at']
      expect(entry).not_to have_key('backtrace')
    ensure
      # Not just a trailing statement: the `wait_for` above timing out
      # (real, more likely on a loaded CI runner) would otherwise raise
      # past it, leaking a live Manager with real Processor threads still
      # `BRPOP`ing the default queue for the rest of the suite run —
      # silently stealing jobs pushed by later, unrelated examples.
      manager&.stop!(timeout: 2)
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

      entries, = Cogworker::History::Storage.page('failed', 1, 10)
      entry = entries.first
      expect(entry['status']).to eq('failed')
      expect(entry['error_class']).to eq('ArgumentError')
      expect(entry['error_message']).to eq('boom')
      expect(entry['backtrace']).to be_an(Array)
      expect(entry['backtrace']).not_to be_empty

      # the History middleware re-raises — the job still ends up dead (retry: false)
      expect(Cogworker::Stats.new.dead_size).to eq(1)
    ensure
      manager&.stop!(timeout: 2) # see the `ensure` comment in the example above
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

      expect(Cogworker::History::Storage.page('success', 1, 10).last).to eq(1)
      expect(Cogworker::History::Storage.page('failed', 1, 10).last).to eq(1)
      expect(Cogworker::History::Storage.page('all', 1, 10).last).to eq(2)
    ensure
      manager&.stop!(timeout: 2) # see the `ensure` comment in the example above
    end
  end

  describe Cogworker::History::Storage do
    it 'paginates newest-first' do
      # Real, near-`Time.now` timestamps — not `0, 1, 2, ...` — because
      # `write_and_trim` now also trims by age (`History.retention_days`):
      # a `finished_at` from the Unix epoch would be trimmed by that same
      # write, before the test ever gets to page through it.
      now = Time.now.to_f
      3.times do |i|
        described_class.record({ 'jid' => "j#{i}", 'class' => 'X', 'args' => [] }, 'default', now + i, now + i + 1,
                               'success')
      end

      page1, total = described_class.page('all', 1, 2)
      expect(total).to eq(3)
      expect(page1.map { |e| e['jid'] }).to eq(%w[j2 j1])

      page2, = described_class.page('all', 2, 2)
      expect(page2.map { |e| e['jid'] }).to eq(%w[j0])
    end

    it 'trims each list independently to History.max_entries, oldest first' do
      Cogworker::History.max_entries = 3
      now = Time.now.to_f
      5.times do |i|
        described_class.record({ 'jid' => "j#{i}", 'class' => 'X', 'args' => [] }, 'default', now + i, now + i + 1,
                               'success')
      end

      _entries, total = described_class.page('all', 1, 10)
      expect(total).to eq(3)
      entries, = described_class.page('all', 1, 10)
      expect(entries.map { |e| e['jid'] }).to eq(%w[j4 j3 j2]) # the 2 oldest (j0, j1) were trimmed
    end

    it 'trims entries older than History.retention_days, regardless of max_entries — the primary, ' \
       'expected trim, not just the count-based safety ceiling' do
      Cogworker::History.retention_days = 7
      Cogworker::History.max_entries = 1000 # far above what this example writes — isolates the age trim alone
      old = Time.now.to_f - (10 * 86_400) # older than the 7-day window
      recent = Time.now.to_f - 86_400 # within it

      described_class.record({ 'jid' => 'stale', 'class' => 'X', 'args' => [] }, 'default', old, old, 'success')
      described_class.record({ 'jid' => 'fresh', 'class' => 'X', 'args' => [] }, 'default', recent, recent,
                             'success')

      entries, total = described_class.page('all', 1, 10)
      expect(total).to eq(1)
      expect(entries.map { |e| e['jid'] }).to eq(%w[fresh])
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

      it "keeps counting a day's runs even once `max_entries` has trimmed those individual entries out of the " \
         '`all`/`success`/`failed` lists — regression test for the whole reason the daily counters exist ' \
         "separately from those lists: a busy queue used to silently make the chart's older days go blank" do
        Cogworker::History.max_entries = 2
        yesterday = Time.now.utc - 86_400

        3.times do |i|
          described_class.record({ 'jid' => "old#{i}", 'class' => 'X', 'args' => [] }, 'default', 0,
                                 yesterday.to_f, 'success')
        end
        # Trims `all`/`success` down to the 2 most recent entries — none of
        # which are "old0" any more.
        entries, total = described_class.page('success', 1, 10)
        expect(total).to eq(2)
        expect(entries.map { |e| e['jid'] }).not_to include('old0')

        counts = described_class.daily_counts(14)

        expect(counts[yesterday.strftime('%Y-%m-%d')]).to eq('success' => 3, 'failed' => 0)
      end
    end
  end

  describe 'Cogworker::History.configure_server_middleware' do
    it 'adds the middleware to the server chain and applies retention_days, max_entries, and ' \
       'daily_stats_retention_days' do
      Cogworker::History.configure_server_middleware(Cogworker.config, retention_days: 14, max_entries: 42,
                                                                       daily_stats_retention_days: 7)
      expect(Cogworker::History.retention_days).to eq(14)
      expect(Cogworker::History.max_entries).to eq(42)
      expect(Cogworker::History.daily_stats_retention_days).to eq(7)
      expect(Cogworker.config.server_chain.map(&:klass)).to include(Cogworker::History::Middleware)
    end
  end
end
