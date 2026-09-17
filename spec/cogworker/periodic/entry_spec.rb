# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Cogworker::Periodic::Entry do
  it 'derives a pjid deterministically from cron+class+args' do
    a = described_class.new(cron: '0 * * * *', class_name: 'X', retry: 0, unique: nil, args: [])
    b = described_class.new(cron: '0 * * * *', class_name: 'X', retry: 0, unique: nil, args: [])
    expect(a.pjid).to eq(b.pjid)
  end

  it 'gives distinct pjids to the same class registered twice with different args (real usage)' do
    a = described_class.new(cron: '10 */1 * * *', class_name: 'RefreshJob', retry: 0, unique: :until_executed, args: [])
    b = described_class.new(cron: '10 */1 * * *', class_name: 'RefreshJob', retry: 0,
                            unique: :until_executed, args: [{ action: :generate, military: true }])
    expect(a.pjid).not_to eq(b.pjid)
  end

  it '#until_executed? reflects the unique mode' do
    expect(described_class.new(cron: '* * * * *', class_name: 'X', retry: 0, unique: :until_executed,
                               args: []).until_executed?).to be(true)
    expect(described_class.new(cron: '* * * * *', class_name: 'X', retry: 0, unique: nil,
                               args: []).until_executed?).to be(false)
  end
end
