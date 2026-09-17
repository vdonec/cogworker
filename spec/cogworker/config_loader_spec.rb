# frozen_string_literal: true

require 'spec_helper'
require 'tempfile'

RSpec.describe Cogworker::ConfigLoader do
  it 'parses :concurrency/:queues with ERB interpolation and symbol keys' do
    Tempfile.create(%w[cogworker .yml]) do |f|
      f.write(<<~YAML)
        ---
        :concurrency: <%= 1 + 2 %>
        :queues:
          - default
          - critical
          - critical
      YAML
      f.flush

      config = described_class.load(f.path)
      expect(config[:concurrency]).to eq(3)
      expect(config[:queues]).to eq(%w[default critical critical])
    end
  end

  it 'returns an empty hash when given no path' do
    expect(described_class.load(nil)).to eq({})
  end
end
