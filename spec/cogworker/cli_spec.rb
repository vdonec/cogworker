# frozen_string_literal: true

require 'spec_helper'
require 'tempfile'

RSpec.describe Cogworker::CLI do
  describe '.parse' do
    it 'parses all documented flags' do
      opts = described_class.parse(%w[-e production -c 7 -r ./config/app.rb -C ./config/cogworker.yml -L ./log/cw.log])

      expect(opts[:environment]).to eq('production')
      expect(opts[:concurrency]).to eq(7)
      expect(opts[:require_path]).to eq('./config/app.rb')
      expect(opts[:config_path]).to eq('./config/cogworker.yml')
      expect(opts[:logfile]).to eq('./log/cw.log')
    end

    it 'expands a repeated -q name,weight flag by repetition, matching BasicFetch weighting' do
      opts = described_class.parse(%w[-q default,3 -q low])
      expect(opts[:queues]).to eq(%w[default default default low])
    end

    it 'does not mutate the argv array passed in' do
      argv = %w[-c 5]
      described_class.parse(argv)
      expect(argv).to eq(%w[-c 5])
    end
  end

  describe '#run' do
    it 'marks the process as a server, applies concurrency/queues, and requires app code before booting the Launcher' do
      cli = described_class.new
      launcher = instance_double(Cogworker::Launcher, run: nil)
      allow(Cogworker::Launcher).to receive(:new).and_return(launcher)

      Tempfile.create(%w[app .rb]) do |f|
        f.write("REQUIRED_APP_MARKER = true\n")
        f.flush

        cli.run(['-c', '4', '-q', 'default', '-r', f.path])
      end

      expect(Cogworker.server?).to be(true)
      expect(Cogworker.config.concurrency).to eq(4)
      expect(Cogworker.config.queues).to eq(['default'])
      expect(Object.const_get(:REQUIRED_APP_MARKER)).to be(true)
      expect(launcher).to have_received(:run)
    end
  end
end
