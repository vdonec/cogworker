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

  it 'defaults max_orphanings to 3 and accepts only a positive Integer' do
    expect(Cogworker.config.max_orphanings).to eq(3)
    Cogworker.config.max_orphanings = 5
    expect(Cogworker.config.max_orphanings).to eq(5)
    expect { Cogworker.config.max_orphanings = 0 }.to raise_error(ArgumentError)
    expect { Cogworker.config.max_orphanings = 2.5 }.to raise_error(ArgumentError)
  end

  it 'defaults orphan_threshold to 5 minutes and accepts only a positive number' do
    expect(Cogworker.config.orphan_threshold).to eq(300)
    Cogworker.config.orphan_threshold = 120
    expect(Cogworker.config.orphan_threshold).to eq(120)
    expect { Cogworker.config.orphan_threshold = -1 }.to raise_error(ArgumentError)
    expect { Cogworker.config.orphan_threshold = nil }.to raise_error(ArgumentError)
  end

  it 'defaults fetch_idle_max_interval to 1s and accepts only a positive number' do
    expect(Cogworker.config.fetch_idle_max_interval).to eq(1.0)
    Cogworker.config.fetch_idle_max_interval = 0.25
    expect(Cogworker.config.fetch_idle_max_interval).to eq(0.25)
    expect { Cogworker.config.fetch_idle_max_interval = 0 }.to raise_error(ArgumentError)
    expect { Cogworker.config.fetch_idle_max_interval = '1' }.to raise_error(ArgumentError)
  end

  it "logs unbuffered by default, so lines written right before Process.exit! aren't lost" do
    reader, writer = IO.pipe
    writer.sync = false
    Cogworker::Logging.default_logger(writer)

    expect(writer.sync).to be(true)
  ensure
    reader&.close
    writer&.close
  end

  it 'flush_output! flushes stdout and stderr' do
    expect($stdout).to receive(:flush)
    expect($stderr).to receive(:flush)

    Cogworker.flush_output!
  end
end
