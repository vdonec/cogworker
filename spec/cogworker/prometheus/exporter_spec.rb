# frozen_string_literal: true

require 'spec_helper'
require 'rack/mock'

RSpec.describe Cogworker::Prometheus::Exporter do
  let(:mock) { Rack::MockRequest.new(Cogworker::Web) }

  around do |example|
    original = Cogworker::Web.prometheus_exporter_enabled
    example.run
    Cogworker::Web.prometheus_exporter_enabled = original
  end

  it 'is reachable without the mounting app ever referencing Cogworker::Prometheus::Exporter itself' do
    expect(mock.get('/metrics').status).to eq(200)
  end

  it 'renders the queue/stats/process gauges in Prometheus text format' do
    Cogworker.config.redis { |c| c.incr('cogworker:stats:processed') }

    body = mock.get('/metrics').body

    expect(body).to include('cogworker_processed_total 1')
    expect(body).to include('# TYPE cogworker_queue_size gauge')
  end

  it 'returns 404 once Web.prometheus_exporter_enabled is set to false' do
    Cogworker::Web.prometheus_exporter_enabled = false

    expect(mock.get('/metrics').status).to eq(404)
  end
end
