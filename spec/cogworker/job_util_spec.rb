# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Cogworker::JobUtil do
  describe '.max_retries' do
    it 'is 0 for the literal boolean false' do
      expect(described_class.max_retries('retry' => false)).to eq(0)
    end

    it 'is the default cap for true' do
      expect(described_class.max_retries('retry' => true)).to eq(described_class::DEFAULT_MAX_RETRY_ATTEMPTS)
    end

    it 'is the default cap when the key is absent (nil)' do
      expect(described_class.max_retries({})).to eq(described_class::DEFAULT_MAX_RETRY_ATTEMPTS)
    end

    it 'is the given count for an explicit Integer' do
      expect(described_class.max_retries('retry' => 3)).to eq(3)
    end
  end

  describe '.terminal_failure?' do
    it 'is true once retry_count already reached the cap' do
      expect(described_class.terminal_failure?('retry' => 2, 'retry_count' => 2)).to be(true)
    end

    it 'is false while retries remain' do
      expect(described_class.terminal_failure?('retry' => 2, 'retry_count' => 1)).to be(false)
    end

    it "doesn't raise for retry: false — the bug this method replaces every ad-hoc " \
       "`job['retry'].to_i` copy of this check with" do
      expect(described_class.terminal_failure?('retry' => false, 'retry_count' => 0)).to be(true)
    end
  end

  describe '.claim_and_requeue' do
    def zadd(raw) = Cogworker.config.redis { |c| c.zadd('cogworker:retry', 1, raw) }
    def call(raw) = Cogworker.config.redis { |c| described_class.claim_and_requeue(c, 'cogworker:retry', raw) }

    it 'requeues a valid entry, and reports :gone to whoever loses the zrem' do
      raw = JSON.generate('jid' => 'a', 'queue' => 'default')
      zadd(raw)

      expect(call(raw)).to eq(:requeued)
      expect(call(raw)).to eq(:gone)
      expect(queued_jobs.map { |j| j['jid'] }).to eq(['a'])
    end

    it 'never claims an entry it could not requeue — no JSON object, or no String queue' do
      ['{not json', '[1]', JSON.generate('jid' => 'b'), JSON.generate('jid' => 'c', 'queue' => nil)].each do |raw|
        zadd(raw)
        expect(call(raw)).to eq(:invalid)
      end

      expect(Cogworker.config.redis { |c| c.zcard('cogworker:retry') }).to eq(4)
    end
  end

  describe '.safe_string' do
    it 'scrubs invalid UTF-8 and binary strings, transcodes other valid encodings, and truncates' do
      expect(described_class.safe_string("bad \xff".b)).to eq("bad \uFFFD")
      expect(described_class.safe_string('Привет'.encode('Windows-1251'))).to eq('Привет')
      expect(described_class.safe_string('abcdef', 3)).to eq('abc')
      expect(JSON.generate('m' => described_class.safe_string("\xff\xfe".b))).to be_a(String)
    end
  end
end
