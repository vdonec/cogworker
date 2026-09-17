# frozen_string_literal: true

require 'spec_helper'
require 'stringio'

RSpec.describe 'Cogworker.configure_server / .configure_client' do
  let(:io) { StringIO.new }

  around do |example|
    original_logger = Cogworker.logger
    Cogworker.logger = Cogworker::Logging.default_logger(io)
    example.run
    Cogworker.logger = original_logger
  end

  describe '.configure_server' do
    it 'yields config and mutates it when server? is true' do
      Cogworker.server_process!
      Cogworker.configure_server { |c| c.queues = ['custom'] }

      expect(Cogworker.config.queues).to eq(['custom'])
    end

    it 'does not yield when server? is false, and says nothing at the default log level' do
      ran = false
      Cogworker.configure_server { ran = true }

      expect(ran).to be(false)
      expect(io.string).to eq('')
    end

    it 'logs at debug why the block was skipped, once verbosity is turned up' do
      Cogworker.logger.level = Logger::DEBUG
      Cogworker.configure_server {}

      expect(io.string).to include('Cogworker.configure_server skipped')
    end
  end

  describe '.configure_client' do
    it 'yields config when server? is false (the default)' do
      Cogworker.configure_client { |c| c.queues = ['custom'] }
      expect(Cogworker.config.queues).to eq(['custom'])
    end

    it 'does not yield when server? is true, and says nothing at the default log level' do
      Cogworker.server_process!
      ran = false
      Cogworker.configure_client { ran = true }

      expect(ran).to be(false)
      expect(io.string).to eq('')
    end

    it 'logs at debug why the block was skipped, once verbosity is turned up' do
      Cogworker.server_process!
      Cogworker.logger.level = Logger::DEBUG
      Cogworker.configure_client {}

      expect(io.string).to include('Cogworker.configure_client skipped')
    end
  end
end
