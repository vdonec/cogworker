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
end
