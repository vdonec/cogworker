# frozen_string_literal: true

require 'spec_helper'
require 'tempfile'

# A real, separate OS process — deliberately not just an in-process
# Heartbeat/Manager pair like other specs use. The one thing this test
# actually needs to prove (a remote 'stop' message ends the *process*, not
# just the Manager) can only be observed by watching an OS process actually
# exit; `Heartbeat#dispatch`'s 'stop' path calls `::Process.exit!`, and
# calling that in-process here would kill the rspec run itself.
RSpec.describe 'Cogworker::Heartbeat remote stop (end-to-end, real OS process)' do
  let(:lib) { File.expand_path('../../lib', __dir__) }

  after do
    next unless @pid

    ::Process.kill('KILL', @pid)
    ::Process.wait(@pid)
  rescue Errno::ESRCH, Errno::ECHILD
    nil
  end

  # `Process.kill(0, pid)` is the wrong tool here: a child we spawned
  # ourselves that has already exited stays a *zombie* — still "present" as
  # far as `kill(0, ...)` is concerned — until something actually reaps it,
  # so that check would never observe the exit at all. `waitpid` with
  # `WNOHANG` both checks *and* reaps in the same call: non-nil the moment
  # the child has terminated, `nil` while it's still running.
  def child_exited?
    !::Process.waitpid(@pid, ::Process::WNOHANG).nil?
  rescue Errno::ECHILD
    true # already reaped by an earlier call
  end

  it 'actually terminates the OS process — it previously only quiesced the Manager forever, leaving the ' \
     'process alive and still heartbeating with no way back to work short of a real kill' do
    script = <<~RUBY
      require 'cogworker'
      Cogworker.config.redis = { url: #{TEST_REDIS_URL.inspect} }
      manager = Cogworker::Manager.new
      manager.start!
      Cogworker::Heartbeat.new(manager).start!
      sleep
    RUBY

    Tempfile.create(%w[heartbeat_remote_stop .rb]) do |f|
      f.write(script)
      f.flush

      @pid = ::Process.spawn(RbConfig.ruby, '-I', lib, f.path, out: File::NULL, err: File::NULL)

      identity = wait_for(timeout: 8) { Cogworker::ProcessSet.new.find { |p| p['pid'] == @pid }&.identity }
      expect(identity).not_to be_nil, 'child process never published its heartbeat presence'
      expect(child_exited?).to be(false)

      Cogworker::ProcessSet.new.find { |p| p.identity == identity }.stop!

      wait_for(timeout: 8) { child_exited? } # raises if it never exits — that's the actual assertion here
      @pid = nil

      # `cleanup_presence!` ran (and completed) before the process exited.
      expect(Cogworker::ProcessSet.new.map(&:identity)).not_to include(identity)
    end
  end
end
