# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Cogworker::Config do
  it 'honors a redis= that comes after the pool was already built' do
    Cogworker.config.redis(&:ping)
    Cogworker.config.redis = { url: TEST_REDIS_URL.sub(%r{/\d+\z}, '/14') }

    db = Cogworker.config.redis { |c| c.connection[:db] }
    expect(db).to eq(14)
  ensure
    Cogworker.config.redis = { url: TEST_REDIS_URL }
  end

  it 'defaults fetch to :reliable and rejects an unknown mode' do
    expect(Cogworker.config.fetch).to eq(:reliable)
    Cogworker.config.fetch = 'basic'
    expect(Cogworker.config.fetch).to eq(:basic)
    expect { Cogworker.config.fetch = :fancy }.to raise_error(ArgumentError, /reliable, basic/)
    expect { Cogworker.config.fetch = nil }.to raise_error(ArgumentError, /got nil/)
  end
end
