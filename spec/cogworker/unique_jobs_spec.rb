# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Cogworker::UniqueJobs do
  describe '.until_executed?' do
    it 'is true for the Symbol a caller\'s cogworker_options may still hold' do
      expect(described_class.until_executed?('unique' => :until_executed)).to be(true)
    end

    it 'is true for the String a popped job round-trips to' do
      expect(described_class.until_executed?('unique' => 'until_executed')).to be(true)
    end

    it 'is false when absent' do
      expect(described_class.until_executed?({})).to be(false)
    end

    it 'is false for any other value' do
      expect(described_class.until_executed?('unique' => :while_executing)).to be(false)
    end
  end

  describe '.digest' do
    it 'is deterministic for the same class/queue/args' do
      job = { 'class' => 'X', 'queue' => 'default', 'args' => [1, 'a'] }
      expect(described_class.digest(job)).to eq(described_class.digest(job.dup))
    end

    it 'differs when args differ' do
      a = { 'class' => 'X', 'queue' => 'default', 'args' => [1] }
      b = { 'class' => 'X', 'queue' => 'default', 'args' => [2] }
      expect(described_class.digest(a)).not_to eq(described_class.digest(b))
    end

    it 'ignores unrelated fields like jid/created_at' do
      base = { 'class' => 'X', 'queue' => 'default', 'args' => [] }
      expect(described_class.digest(base.merge('jid' => 'a', 'created_at' => 1)))
        .to eq(described_class.digest(base.merge('jid' => 'b', 'created_at' => 2)))
    end
  end
end
