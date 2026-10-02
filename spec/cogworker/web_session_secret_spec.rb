# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Cogworker::Web.session_secret' do
  around do |example|
    saved_secret = Cogworker::Web.instance_variable_get(:@session_secret)
    saved_env = ENV.fetch('COGWORKER_SESSION_SECRET', nil)
    Cogworker::Web.instance_variable_set(:@session_secret, nil)
    example.run
  ensure
    ENV['COGWORKER_SESSION_SECRET'] = saved_env
    Cogworker::Web.session_secret = saved_secret
  end

  it 'reads COGWORKER_SESSION_SECRET, so every process of a deployment signs with the same key' do
    ENV['COGWORKER_SESSION_SECRET'] = 'x' * 64
    expect(Cogworker::Web.session_secret).to eq('x' * 64)
  end

  it 'can be set explicitly, and rebuilds the app so the new secret actually applies' do
    Cogworker::Web.call(Rack::MockRequest.env_for('/'))
    Cogworker::Web.session_secret = 'y' * 64

    expect(Cogworker::Web.session_secret).to eq('y' * 64)
    expect(Cogworker::Web.instance_variable_get(:@app)).to be_nil
  end
end
