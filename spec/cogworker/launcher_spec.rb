# frozen_string_literal: true

require 'spec_helper'
require 'stringio'

RSpec.describe Cogworker::Launcher do
  subject(:launcher) { described_class.new }

  it 'resolves periodic job classes before starting any processor thread' do
    manager = launcher.instance_variable_get(:@manager)
    %i[@scheduled @heartbeat @ticker].each { |ivar| allow(launcher.instance_variable_get(ivar)).to receive(:start!) }
    allow(launcher).to receive(:install_signal_traps)
    allow(launcher).to receive(:watch_signals)

    expect(launcher).to receive(:resolve_periodic_classes).ordered
    expect(manager).to receive(:start!).ordered

    launcher.run
  end

  it 'resolves each periodic class on the calling thread, and only logs one that cannot be resolved' do
    stub_const('LauncherSpecPeriodicJob', Class.new)
    Cogworker.config.periodic do |mgr|
      mgr.register '* * * * *', 'LauncherSpecPeriodicJob'
      mgr.register '* * * * *', 'NoSuchPeriodicJob'
    end
    log = StringIO.new
    allow(Cogworker).to receive(:logger).and_return(Cogworker::Logging.default_logger(log))
    resolved = []
    allow(Object).to receive(:const_get).and_wrap_original do |original, name, *rest|
      resolved << [name, Thread.current] if name.to_s.end_with?('PeriodicJob')
      original.call(name, *rest)
    end

    expect { launcher.send(:resolve_periodic_classes) }.not_to raise_error

    expect(resolved).to eq([['LauncherSpecPeriodicJob', Thread.current], ['NoSuchPeriodicJob', Thread.current]])
    expect(log.string).to include("periodic job class NoSuchPeriodicJob can't be resolved")
  end
end
