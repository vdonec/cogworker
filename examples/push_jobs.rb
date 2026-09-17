# frozen_string_literal: true

# Enqueues a few jobs so there's something to watch a running
# `exe/cogworker`/`exe/cogworkerswarm` process (and the Web UI) do:
#
#   bundle exec ruby ./examples/push_jobs.rb

require_relative 'init'

3.times { |i| GreetingJob.perform_async("world #{i}") }
GreetingJob.perform_in(10, 'delayed world')
FlakyJob.perform_async(2) # fails twice, then succeeds on the 3rd attempt
2.times { |i| LowPriorityJob.perform_async("background task #{i}") } # queue: 'low', not 'default'

puts 'Pushed 3x GreetingJob (immediate, queue "default"), 1x GreetingJob (in 10s), ' \
     '1x FlakyJob, 2x LowPriorityJob (queue "low").'
puts 'Watch a running worker process it, or check status with:'
puts '  Cogworker::Status.status(jid)  # jid returned by *_async/*_in'
