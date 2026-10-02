# frozen_string_literal: true

require 'spec_helper'

# In-process: exercises Swarm's respawn bookkeeping with `fork_child` and the
# clock stubbed. swarm_spec.rb covers the real exe/cogworkerswarm end to end.
RSpec.describe Cogworker::Swarm do
  subject(:swarm) { described_class.new([], count: 1) }

  let(:now) { [1000.0] }

  before do
    allow(swarm).to receive(:monotonic_now) { now.first }
    allow(swarm).to receive(:fork_child) do |slot|
      pid = rand(100_000)
      swarm.instance_variable_get(:@children)[pid] = slot
      swarm.instance_variable_get(:@started_at)[slot] = now.first
      pid
    end
  end

  def crash(slot = 0)
    pid = swarm.instance_variable_get(:@children).key(slot)
    swarm.instance_variable_get(:@children).delete(pid)
    swarm.send(:schedule_respawn, pid, slot)
    swarm.instance_variable_get(:@pending_respawns)[slot] - now.first
  end

  it 'backs off exponentially while a slot keeps crashing right after start, capped at RESPAWN_MAX_DELAY' do
    swarm.send(:fork_child, 0)
    delays = Array.new(9) do
      delay = crash
      now[0] += delay
      swarm.send(:respawn_due_children)
      delay
    end

    expect(delays).to eq([0, 1, 2, 4, 8, 16, 32, 60, 60])
  end

  it 'does not respawn before the backoff has elapsed' do
    swarm.send(:fork_child, 0)
    crash
    swarm.send(:respawn_due_children) # first quick crash: respawned at once
    expect(crash).to eq(1)

    now[0] += 0.5
    swarm.send(:respawn_due_children)
    expect(swarm.instance_variable_get(:@children)).to be_empty

    now[0] += 0.5
    swarm.send(:respawn_due_children)
    expect(swarm.instance_variable_get(:@children).values).to eq([0])
  end

  it 'resets the backoff once a child has stayed up for HEALTHY_UPTIME' do
    swarm.send(:fork_child, 0)
    3.times do
      now[0] += crash
      swarm.send(:respawn_due_children)
    end
    now[0] += described_class::HEALTHY_UPTIME

    expect(crash).to eq(0)
  end

  it 'logs, rather than raising NameError, on an unknown queued signal' do
    swarm.instance_variable_get(:@signal_queue) << :bogus

    expect { swarm.send(:drain_signals) }.not_to raise_error
  end

  it 'force-kills, once, a child still alive GRACEFUL_STOP_TIMEOUT after a stop was relayed' do
    swarm.send(:fork_child, 0)
    pid = swarm.instance_variable_get(:@children).keys.first
    kills = []
    allow(swarm).to receive(:safe_kill) { |p, sig| kills << [p, sig] }

    swarm.send(:initiate_stop)
    swarm.send(:kill_stragglers)
    expect(kills).to eq([[pid, Cogworker::Signals::STOP]])

    now[0] += described_class::GRACEFUL_STOP_TIMEOUT + 1
    2.times { swarm.send(:kill_stragglers) }
    expect(kills).to eq([[pid, Cogworker::Signals::STOP], [pid, 'KILL']])
  end
end
