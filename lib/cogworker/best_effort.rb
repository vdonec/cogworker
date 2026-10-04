# frozen_string_literal: true

module Cogworker
  # Runs a write whose failure must not change a job's fate — the
  # bookkeeping built-in server middleware does around `perform` (history,
  # status, releasing locks). Its error is logged (collapsed by RedisErrors
  # while Redis is away) and swallowed: raised from a middleware, it used to
  # be indistinguishable from the job's own error, so a job that ran fine
  # was routed as failed — retried (run again), or with `retry: false`,
  # buried in dead.
  module BestEffort
    module_function

    def call(what)
      result = yield
      RedisErrors.recovered(what)
      result
    rescue StandardError => e
      RedisErrors.report(what, e)
      nil
    end
  end
end
