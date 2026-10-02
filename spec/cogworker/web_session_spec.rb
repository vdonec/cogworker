# frozen_string_literal: true

require 'spec_helper'
require 'rack'
require 'rack/builder'
require 'rack/mock'
require 'rack/session/cookie'

RSpec.describe 'Cogworker::Web built-in session' do
  # Stands in for an auth middleware added via `Web.use`: it writes to
  # whatever session it is handed.
  let(:session_writer) do
    Class.new do
      def initialize(app) = @app = app

      def call(env)
        env['rack.session']&.[]=('user', 'alice')
        @app.call(env)
      end
    end
  end

  around do |example|
    saved = Cogworker::Web.instance_variable_get(:@middlewares)
    Cogworker::Web.instance_variable_set(:@middlewares, [])
    Cogworker::Web.use(session_writer)
    example.run
  ensure
    Cogworker::Web.instance_variable_set(:@middlewares, saved)
    Cogworker::Web.builtin_session = true
  end

  def cookie_names(response)
    Array(response.headers['set-cookie']).join("\n").scan(/^\s*([\w.]+)=/).flatten
  end

  it "steps aside for the host app's own session: Web.use middleware writes the host's, no second cookie" do
    host = Rack::Builder.new
    host.use(Rack::Session::Cookie, secret: 'h' * 64, key: 'host.session')
    host.run(Cogworker::Web)

    response = Rack::MockRequest.new(host.to_app).get('/jobs')

    expect(cookie_names(response)).to eq(['host.session'])
  end

  it 'still provides a session when the host has none' do
    response = Rack::MockRequest.new(Cogworker::Web).get('/jobs')

    expect(cookie_names(response)).to eq(['cogworker.session'])
  end

  it 'can be switched off entirely' do
    Cogworker::Web.builtin_session = false

    response = Rack::MockRequest.new(Cogworker::Web).get('/jobs')

    expect(response.status).to eq(200)
    expect(cookie_names(response)).to be_empty
  end
end
