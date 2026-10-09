# frozen_string_literal: true

require 'json'

module Cogworker
  # Runs the death hooks for a job that has just been written to dead for
  # good: the job class's own `cogworker_retries_exhausted`, then every
  # `config.death_handlers` entry, in order. Called only by whoever's write
  # actually put it there (so at most once per death), after that write —
  # and, from a processor, only once the job is acknowledged, so a slow
  # hook can't leave it on the in-progress list to be requeued and re-run.
  #
  # Each hook gets its own copy of the job (as stored in dead) and runs on
  # its own: one that raises is logged and never stops the others, nor the
  # ack / lock releases / reconcile pass around the call. Synchronous, with
  # no timeout — a hook should be quick.
  module DeathNotifier
    module_function

    def notify(job, exception)
      hook = job_class(job['class'])&.cogworker_retries_exhausted_block
      run('cogworker_retries_exhausted', job) { |copy| JobUtil.call_hook(hook, copy, exception) } if hook
      Cogworker.config.death_handlers.each do |handler|
        run('death handler', job) { |copy| JobUtil.call_hook(handler, copy, exception) }
      end
    end

    # A dead entry filed from its stored record (no exception object left).
    def notify_failed(payload)
      job = parse(payload)
      notify(job, JobFailedError.new(job['error_message'].to_s)) if job
    end

    def notify_orphaned(job)
      notify(job, JobOrphanedError.new("orphaned more than #{Cogworker.config.max_orphanings} times"))
    end

    def run(what, job)
      yield JobUtil.deep_copy(job)
    rescue Exception => e # rubocop:disable Lint/RescueException -- user code, isolated like `perform`
      Cogworker.logger.error do
        "#{what} failed for jid=#{job['jid']} (ignored): #{e.class}: #{JobUtil.error_message(e)}"
      end
    end

    # nil for a class that can't be loaded (renamed, removed, never defined)
    # or doesn't use the job DSL: only `death_handlers` run then.
    def job_class(name)
      return nil unless name.is_a?(String) && !name.empty?

      klass = Object.const_get(name)
      klass.respond_to?(:cogworker_retries_exhausted_block) ? klass : nil
    rescue StandardError
      nil
    end

    def parse(payload)
      job = JSON.parse(payload)
      job.is_a?(Hash) ? job : nil
    rescue JSON::ParserError, TypeError
      nil
    end
  end
end
