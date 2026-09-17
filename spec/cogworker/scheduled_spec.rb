# frozen_string_literal: true

require 'spec_helper'
require 'json'

RSpec.describe Cogworker::Scheduled do
  it 'graduates a due job from cogworker:schedule into its queue' do
    job = { 'jid' => 'abc', 'class' => 'X', 'queue' => 'default', 'args' => [] }
    raw = JSON.generate(job)
    Cogworker.config.redis { |c| c.zadd('cogworker:schedule', Time.now.to_f - 10, raw) }

    manager = instance_double(Cogworker::Manager, stopping?: false, quiet?: false)
    described_class.new(manager).send(:enqueue_due_jobs)

    expect(Cogworker.config.redis { |c| c.zcard('cogworker:schedule') }).to eq(0)
    expect(Cogworker.config.redis { |c| c.lrange('cogworker:queue:default', 0, -1) }).to eq([raw])
  end

  it 'does not graduate a job scheduled for the future' do
    job = { 'jid' => 'abc', 'class' => 'X', 'queue' => 'default', 'args' => [] }
    raw = JSON.generate(job)
    Cogworker.config.redis { |c| c.zadd('cogworker:schedule', Time.now.to_f + 3600, raw) }

    manager = instance_double(Cogworker::Manager, stopping?: false, quiet?: false)
    described_class.new(manager).send(:enqueue_due_jobs)

    expect(Cogworker.config.redis { |c| c.zcard('cogworker:schedule') }).to eq(1)
    expect(Cogworker.config.redis { |c| c.llen('cogworker:queue:default') }).to eq(0)
  end
end
