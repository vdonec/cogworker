# frozen_string_literal: true

# A periodic job, registered below in init.rb via
# `config.periodic { |mgr| mgr.register(...) }` — not scheduled by anything
# in this file itself, `perform` just needs to exist like any other job.
#
# `perform` takes a plain positional Hash, not Ruby keyword arguments: the
# job hash's `args` round-trips through JSON, so by the time it reaches
# here any keys are Strings, not Symbols — passing that as `**opts`/keyword
# args would raise. Accepting `*args` and pulling `args.first` (as real
# periodic job base classes do) sidesteps this entirely.
class DailyReportJob
  include Cogworker::Worker

  def perform(*args)
    opts = args.first || {}
    section = opts['section'] || opts[:section] || 'default'
    Cogworker.logger.info { "Generating daily report for section=#{section}" }
  end
end
