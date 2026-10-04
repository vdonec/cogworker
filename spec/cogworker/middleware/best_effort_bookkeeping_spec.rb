# frozen_string_literal: true

require 'spec_helper'
require 'stringio'

# The built-in server middleware's own writes around `perform` must never
# change a job's outcome: a job that ran fine stays a success when Redis
# fails right after it, and the job's own error is the one re-raised.
RSpec.describe 'built-in server middleware bookkeeping' do
  let(:job) do
    { 'jid' => 'b1', 'class' => 'X', 'queue' => 'default', 'args' => [], 'unique' => 'until_executed',
      'periodic_pjid' => 'pjb' }
  end
  let(:failing_redis) { Redis::CommandError.new("READONLY You can't write against a read only replica.") }

  before { allow(Cogworker).to receive(:logger).and_return(Cogworker::Logging.default_logger(StringIO.new)) }

  [
    Cogworker::History::Middleware.new,
    Cogworker::Periodic::ReleaseMiddleware.new,
    Cogworker::UniqueJobs::ReleaseMiddleware.new,
    Cogworker::Status::ServerMiddleware.new(60)
  ].each do |middleware|
    describe middleware.class do
      before do
        allow(Cogworker::History::Storage).to receive(:record).and_raise(failing_redis)
        allow(Cogworker::Periodic::RunningLock).to receive(:release).and_raise(failing_redis)
        allow(Cogworker::Periodic::RunningLock).to receive(:touch).and_raise(failing_redis)
        allow(Cogworker::OwnedKey).to receive(:delete).and_raise(failing_redis)
        allow(Cogworker::Status::Storage).to receive(:write).and_raise(failing_redis)
      end

      it "doesn't turn a job that ran fine into a failure when its own write fails" do
        ran = false
        expect { middleware.call(nil, job.dup, 'default') { ran = true } }.not_to raise_error
        expect(ran).to be(true)
      end

      it "re-raises the job's own error, not its write's" do
        failing = job.merge('retry' => 0, 'retry_count' => 0)
        expect { middleware.call(nil, failing, 'default') { raise ArgumentError, 'job boom' } }
          .to raise_error(ArgumentError, 'job boom')
      end
    end
  end
end
