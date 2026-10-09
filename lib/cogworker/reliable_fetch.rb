# frozen_string_literal: true

require 'digest/sha1'
require 'json'

module Cogworker
  # The default fetch (`config.fetch = :reliable`): every job is moved
  # atomically (`LMOVE`, Redis >= 6.2) from its queue onto this process's own
  # `cogworker:inprogress:<identity>` list, and only removed from there
  # (`acknowledge`) once it has finished — succeeded, or been routed to
  # retry/dead. A job is therefore never only in a processor's memory: if the
  # process dies mid-job (OOM, SIGKILL, a host going away), the job is still
  # on that list, and `recover_orphans` (run by every live process's
  # `Scheduled` poller) puts it back on its queue once the dead process has
  # gone `config.orphan_threshold` (default 5 min) without a heartbeat. The trade-off is at-least-once delivery: a job
  # that was partly done when its process died runs again from the start.
  #
  # `LMOVE` can only take from one list at a time, so there's no blocking
  # wait across several weighted queues the way `BasicFetch`'s single
  # `BRPOP` has: instead, one round trip (FETCH_SCRIPT) tries the queues in
  # weighted-shuffled order and takes the first job it finds, and an empty
  # round sleeps EMPTY_POLL_INTERVAL before the next. Weighting and
  # `Queue#pause!` behave exactly as in BasicFetch.
  class ReliableFetch < BasicFetch
    # The first pause after an empty round; each further empty round in a
    # row doubles it, up to `config.fetch_idle_max_interval` (default 1s),
    # and finding a job resets it. That cap is the worst-case pickup delay
    # on an idle process — the trade-off against how often idle processors
    # poll Redis (at 0.25s flat, 4 calls/s per thread).
    EMPTY_POLL_INTERVAL = 0.25
    # A queue counts as read if a live process stamped it (every heartbeat)
    # this recently.
    LIVE_QUEUE_WINDOW = 2 * Heartbeat::TTL
    ORPHANINGS_TTL = 7 * 24 * 60 * 60
    MIN_REDIS_VERSION = Gem::Version.new('6.2')

    # KEYS[1..n-1] = queue keys, in the order to try; KEYS[n] = in-progress list.
    FETCH_SCRIPT = <<~LUA
      local dest = KEYS[#KEYS]
      for i = 1, #KEYS - 1 do
        local job = redis.call("LMOVE", KEYS[i], dest, "RIGHT", "LEFT")
        if job then
          return {KEYS[i], job}
        end
      end
      return false
    LUA

    # (Run by hash, like every script here — see LuaScript.)
    FETCH_SCRIPT_SHA = LuaScript.sha(FETCH_SCRIPT)

    # Lua shared by every script here that puts a job back on its queue:
    # onto the end its queue is popped from (so it runs next), onto
    # `default_queue` if its own `queue` can't be read (the Processor then
    # buries it as unparseable) — and a job from an `until_executed`
    # periodic entry re-takes its running lock on the way
    # (Periodic::RunningLock::RETAKE_FUNCTION), so the ticker can't start
    # the next slot alongside the requeued run.
    REQUEUE_JOB_FUNCTION = Periodic::RunningLock::RETAKE_FUNCTION + <<~LUA
      local function requeue_job(job, queue_prefix, default_queue, lock_prefix, lock_ttl)
        local queue = default_queue
        local ok, decoded = pcall(cjson.decode, job)
        if ok and type(decoded) == "table" then
          if type(decoded["queue"]) == "string" and decoded["queue"] ~= "" then
            queue = decoded["queue"]
          end
          local pjid, jid = decoded["periodic_pjid"], decoded["jid"]
          if decoded["periodic_until_executed"] == true and type(pjid) == "string" and type(jid) == "string" then
            retake_running_lock(lock_prefix .. pjid, jid, lock_ttl)
          end
        end
        redis.call("RPUSH", queue_prefix .. queue, job)
        return queue
      end
    LUA

    # KEYS[1] = an in-progress list, KEYS[2] = its owner's presence key,
    # KEYS[3] = LAST_BEAT; ARGV[1..4] = requeue_job's prefix/default
    # queue/lock prefix/lock TTL, ARGV[5] = owner identity, ARGV[6] = orphan
    # threshold, or "" to requeue unconditionally (this process's own list,
    # on shutdown), ARGV[7] = the caller's clock (epoch s) in case TIME is
    # refused; ARGV[8] = orphan-counter key prefix, ARGV[9] = its TTL,
    # ARGV[10] = config.max_orphanings, ARGV[11..] = jobs to drop or keep
    # (see below); KEYS[4] = REPEAT_ORPHANS, KEYS[5] = cogworker:dead.
    # Returns {moved, failed, n, <n unlisted queue names>..., <jobs filed
    # straight into dead, raw>...}, or {-1, 0, 0} if the owner turned out to
    # be alive. KEYS[6] = cogworker:queues, KEYS[7] = LIVE_QUEUES.
    # Oldest first, so recovered jobs keep their order. The "is the owner
    # really dead?" check is made here, atomically with the requeue:
    # checked separately, an owner that
    # beat in between would lose jobs it is still running to a second run.
    # Atomic per call, so two processes recovering one list can't both move
    # a job.
    REQUEUE_SCRIPT = REQUEUE_JOB_FUNCTION + <<~LUA
      if ARGV[6] ~= "" then
        if redis.call("EXISTS", KEYS[2]) == 1 then
          return {-1, 0, 0}
        end
        -- A stamp that isn't a number counts as no stamp (the presence key
        -- alone then decides); TIME refused (ACL, proxy) falls back to the
        -- caller's clock (ARGV[7]) rather than failing the whole check.
        local last = tonumber(redis.call("HGET", KEYS[3], ARGV[5]) or "")
        if last then
          if redis.replicate_commands then redis.replicate_commands() end
          local now = tonumber(ARGV[7])
          local ok, time = pcall(redis.call, "TIME")
          if ok then now = tonumber(time[1]) end
          if now - last <= tonumber(ARGV[6]) then
            return {-1, 0, 0}
          end
        end
      end
      -- ARGV[11..] = jobs (as on the list) to leave alone instead of
      -- requeueing: "d:<job>" ones are dropped (they finished, only their
      -- ack failed — dropping them is the ack), "k:<job>" ones are kept on
      -- the list (they ran; see Manager#requeue_unfinished).
      local finished, keep = {}, {}
      for i = 11, #ARGV do
        local mark, payload = string.sub(ARGV[i], 1, 2), string.sub(ARGV[i], 3)
        if mark == "d:" then finished[payload] = true else keep[payload] = true end
      end
      if redis.replicate_commands then redis.replicate_commands() end
      local clock = tonumber(ARGV[7])
      local clock_ok, clock_reply = pcall(redis.call, "TIME")
      if clock_ok then clock = tonumber(clock_reply[1]) end
      local moved = 0
      local kept = {}
      local buried = {} -- filed straight into dead, raw: the caller completes them
      local failed = 0  -- couldn't be requeued (kept, at the back): the caller logs them
      local unlisted = {} -- queues requeued onto that no live process reads
      -- One pass over the list as it stands. Each job is peeked, written
      -- where it goes, and only then taken off: a script stopped by an
      -- error keeps the writes it made before it (Redis doesn't roll them
      -- back), so popping first lost the job whenever the write after it
      -- failed. A job whose requeue fails (its queue key of the wrong type)
      -- goes to the back of the list instead, so it can't hold up the ones
      -- behind it — it's retried on the next pass.
      for _ = 1, redis.call("LLEN", KEYS[1]) do
        local job = redis.call("LINDEX", KEYS[1], 0)
        if not job then
          break
        end
        if finished[job] then
          redis.call("LPOP", KEYS[1])
          local ok, decoded = pcall(cjson.decode, job)
          if ok and type(decoded) == "table" and type(decoded["jid"]) == "string" then
            redis.pcall("DEL", ARGV[8] .. decoded["jid"]) -- it finished: its orphan count is moot
          end
        elseif keep[job] then
          table.insert(kept, redis.call("LPOP", KEYS[1]))
        else
          -- Only when recovering from a dead process (not a shutdown's own
          -- requeue): count how often this jid was orphaned, and park it
          -- for `dead` past the limit — a job that itself kills its process
          -- (OOM, SIGKILL) would otherwise come back after every crash,
          -- forever. The counter is best-effort, and only bumped once the
          -- job has been written.
          local counter = nil
          local parked = false
          if ARGV[6] ~= "" then
            local ok, decoded = pcall(cjson.decode, job)
            if ok and type(decoded) == "table" and type(decoded["jid"]) == "string" then
              counter = ARGV[8] .. decoded["jid"]
              local current = redis.pcall("GET", counter)
              local count = type(current) == "string" and tonumber(current) or nil
              if count == nil and current then
                -- Ours, but unusable (not a number, or not even a string):
                -- start over, rather than let it switch the limit off.
                redis.pcall("DEL", counter)
              end
              count = (count or 0) + 1
              if count > tonumber(ARGV[10]) then
                parked = type(redis.pcall("RPUSH", KEYS[4], job)) == "number"
                -- Parking list unusable: straight to dead (without the
                -- explanatory error a parked one gets), rather than let the
                -- limit be bypassed.
                if not parked then
                  parked = type(redis.pcall("ZADD", KEYS[5], ARGV[7], job)) == "number"
                  if parked then table.insert(buried, job) end
                end
              end
            end
          end
          local written, queue = parked, nil
          if not parked then
            written, queue = pcall(requeue_job, job, ARGV[1], ARGV[2], ARGV[3], ARGV[4])
          end
          -- A queue no live process has said it reads lately (KEYS[7]): tell
          -- the caller, since nothing may be reading it — and list it
          -- (KEYS[6]) so the Web UI shows it.
          if written and queue then
            local seen = tonumber(redis.pcall("ZSCORE", KEYS[7], queue) or "")
            if not seen or seen < clock - #{LIVE_QUEUE_WINDOW} then
              redis.pcall("SADD", KEYS[6], queue)
              unlisted[queue] = true
            end
          end
          redis.call("LPOP", KEYS[1])
          if written then
            if counter then
              redis.pcall("INCR", counter)
              redis.pcall("EXPIRE", counter, ARGV[9])
            end
            moved = moved + 1
          else
            redis.call("RPUSH", KEYS[1], job)
            failed = failed + 1
          end
        end
      end
      for _, job in ipairs(kept) do
        redis.call("RPUSH", KEYS[1], job)
      end
      local names = {}
      for name in pairs(unlisted) do table.insert(names, name) end
      local reply = {moved, failed, #names}
      for _, name in ipairs(names) do table.insert(reply, name) end
      for _, job in ipairs(buried) do table.insert(reply, job) end
      return reply
    LUA

    # KEYS[1] = REPEAT_ORPHANS, KEYS[2] = cogworker:dead; ARGV[1] = parked
    # job, ARGV[2] = score, ARGV[3] = its dead entry. Moved in one step.
    # (Head of the list only — the caller walks it in order — so no LPOS,
    # which Redis < 6.0.6 lacks: this runs in `:basic` mode too.)
    BURY_ORPHAN_SCRIPT = <<~LUA
      if redis.call("LINDEX", KEYS[1], 0) ~= ARGV[1] then
        return 0
      end
      redis.call("ZADD", KEYS[2], ARGV[2], ARGV[3])
      redis.call("LPOP", KEYS[1])
      return 1
    LUA

    # KEYS[1] = an in-progress list; ARGV[1] = one job on it, ARGV[2..5] =
    # requeue_job's arguments. That one job, if still on the list, back on
    # its queue: `give_back`, and `reconcile`'s strays.
    # Present? Write, then remove — see REQUEUE_SCRIPT for why that order.
    REQUEUE_ONE_SCRIPT = REQUEUE_JOB_FUNCTION + <<~LUA
      if not redis.call("LPOS", KEYS[1], ARGV[1]) then
        return 0
      end
      requeue_job(ARGV[1], ARGV[2], ARGV[3], ARGV[4], ARGV[5])
      redis.call("LREM", KEYS[1], 1, ARGV[1])
      return 1
    LUA

    # KEYS[1] = in-progress list, KEYS[2] = retry/dead ZSET; ARGV[1] = the
    # job as fetched, ARGV[2] = score, ARGV[3] = payload to file. Off the
    # in-progress list and into the ZSET in one step; a no-op if it's no
    # longer in progress (already requeued by a shutdown).
    INTERRUPT_SCRIPT = <<~LUA
      if not redis.call("LPOS", KEYS[1], ARGV[1]) then
        return 0
      end
      redis.call("ZADD", KEYS[2], ARGV[2], ARGV[3])
      redis.call("LREM", KEYS[1], 1, ARGV[1])
      if KEYS[3] then redis.pcall("DEL", KEYS[3]) end -- it ran to the end: its orphan count is moot
      return 1
    LUA

    # KEYS[1] = in-progress list, KEYS[2] = UNSETTLED; ARGV[1] = the job as
    # fetched, ARGV[2] = its {set, score, payload} record. Present? Hand
    # over, then remove.
    PARK_UNSETTLED_SCRIPT = <<~LUA
      if not redis.call("LPOS", KEYS[1], ARGV[1]) then
        return 0
      end
      redis.call("RPUSH", KEYS[2], ARGV[2])
      redis.call("LREM", KEYS[1], 1, ARGV[1])
      return 1
    LUA

    # KEYS[1] = UNSETTLED, KEYS[2] = the job's orphan counter; ARGV[1] = one
    # record (its head), ARGV[2..4] =
    # set, score, payload. Filed, then removed.
    FILE_UNSETTLED_SCRIPT = <<~LUA
      if redis.call("LINDEX", KEYS[1], 0) ~= ARGV[1] then
        return 0
      end
      redis.call("ZADD", ARGV[2], ARGV[3], ARGV[4])
      redis.call("LPOP", KEYS[1])
      redis.pcall("DEL", KEYS[2]) -- it ran to the end: its orphan count is moot
      return 1
    LUA

    # KEYS[1] = cogworker:dead; ARGV[1] = an entry, ARGV[2] = score,
    # ARGV[3] = its replacement. Swapped in one step: two commands could
    # leave both in dead (and Retry on each from the Web UI ran it twice).
    SWAP_DEAD_ENTRY_SCRIPT = <<~LUA
      if not redis.call("ZSCORE", KEYS[1], ARGV[1]) then
        return 0
      end
      redis.call("ZADD", KEYS[1], ARGV[2], ARGV[3])
      redis.call("ZREM", KEYS[1], ARGV[1])
      return 1
    LUA

    # KEYS[1] = in-progress list, KEYS[2] = the job's orphan counter.
    ACK_SCRIPT = <<~LUA
      redis.call("LREM", KEYS[1], 1, ARGV[1])
      redis.pcall("DEL", KEYS[2])
      return 1
    LUA

    @pending_raw_burials = []
    @raw_burials_mutex = Mutex.new

    class << self
      # A connection error propagates: can't tell yet, so the caller
      # (Manager#fetch_class) resolves again on its next use, instead of
      # memoizing a guess made while Redis was unreachable. Anything else
      # (INFO restricted, an odd version string) assumes a current server —
      # the runtime fall-back (UnsupportedError) still catches a wrong guess.
      def supported?
        version = Cogworker.config.redis { |c| c.info('server')['redis_version'] }
        Gem::Version.new(version) >= MIN_REDIS_VERSION
      rescue StandardError => e
        raise if RedisErrors.unavailable?(e)

        true
      end

      # Puts every job still on `identity`'s in-progress list back on its
      # queue; returns how many — or -1 if `if_dead_for:` is given and the
      # owner turns out not to be dead (see REQUEUE_SCRIPT). Used without
      # it for this process's own unfinished jobs on shutdown
      # (`Manager#stop!`), with it for presumed-dead processes' lists.
      #
      # `except:` — jobs on the list that already finished but whose ack
      # failed: dropped from it (which is their ack) rather than requeued,
      # in the same atomic step. `keep:` — jobs left on the list untouched.
      def requeue_in_progress(identity, if_dead_for: nil, except: [], keep: [])
        moved, failed, unlisted_count, *rest = Cogworker.config.redis do |c|
          LuaScript.run(c, REQUEUE_SCRIPT,
                        keys: [RedisKeys.in_progress(identity), RedisKeys.process(identity), RedisKeys::LAST_BEAT,
                               RedisKeys::REPEAT_ORPHANS, RedisKeys::DEAD, RedisKeys::QUEUES, RedisKeys::LIVE_QUEUES],
                        argv: [*requeue_args, identity, if_dead_for.to_s, Time.now.to_i,
                               RedisKeys::ORPHANINGS_PREFIX, ORPHANINGS_TTL, Cogworker.config.max_orphanings,
                               *except.map { |raw| "d:#{raw}" }, *keep.map { |raw| "k:#{raw}" }])
        end
        unlisted = rest.shift(unlisted_count)
        complete_raw_burials(rest)
        unless unlisted.empty?
          Cogworker.logger.warn do
            "requeued job(s) from #{identity} onto queue(s) no live process reads: #{unlisted.join(', ')} " \
              '— make sure some worker reads them'
          end
        end
        if failed.positive?
          Cogworker.logger.error do
            "#{failed} job(s) left in progress by #{identity} couldn't be put back on their queue " \
              '(a key of the wrong type?) — kept, retried on the next pass'
          end
        end
        moved
      end

      def requeue_args
        [RedisKeys::QUEUE_PREFIX, 'default', RedisKeys.periodic_running(''), Periodic::RunningLock.queued_ttl]
      end

      # Requeues the in-progress list of every process that has died without
      # a clean shutdown. "Dead" means its presence key is gone (no beat for
      # Heartbeat::TTL) *and* `config.orphan_threshold` has passed since its
      # last recorded beat (LAST_BEAT, on Redis's clock) — the presence key
      # alone expires after a minute, too eagerly for a live process that
      # merely couldn't beat for a while (a Redis outage or failover, a long
      # GVL-holding call), whose running jobs would then run twice. With no
      # recorded beat at all (lists from before LAST_BEAT existed), the
      # presence key alone decides. Checked inside REQUEUE_SCRIPT, atomically
      # with the requeue. A process always beats before its first fetch
      # (`Heartbeat#start!`). Walks IN_PROGRESS_IDENTITIES (each
      # reliable-fetch process registers itself there on every beat) rather
      # than SCANning the keyspace; `scan: true` (once per reliable process,
      # at boot) also picks up lists from before that set existed.
      #
      # One identity that can't be processed (its list of the wrong type, a
      # corrupt stamp, ...) is logged and skipped — it must never stop the
      # others, let alone the poller or the cron ticker waiting on it.
      #
      # `report:` (a Hash, if given) gets `:registry` / `:scan` set to
      # whether reading that source of candidates worked — what tells the
      # caller a pass really looked, as opposed to one that just survived.
      def recover_orphans(scan: false, report: {})
        own = Cogworker.identity
        moved = candidate_identities(scan: scan, report: report).sum do |identity|
          next 0 if identity == own

          recover_identity(identity)
        rescue StandardError => e
          report[:connection_lost] = true if RedisErrors.unavailable?(e)
          RedisErrors.report('Orphan recovery', e) { "skipped #{identity}" }
          0
        end
        isolated('burying repeat orphans', nil, report) { bury_repeat_orphans }
        isolated('completing dead entries', nil, report) { retry_raw_burials }
        isolated('filing unsettled jobs', nil, report) { file_unsettled }
        RedisErrors.recovered('Orphan recovery') unless report[:connection_lost]
        moved
      end

      # Files every job REQUEUE_SCRIPT parked (orphaned more than
      # `config.max_orphanings` times) in `dead`, with an error saying why — whatever
      # its `retry` setting, since each of those runs ended with its process
      # gone rather than an error to retry on. Parked entries survive a
      # failure here and are picked up on the next pass. Death hooks run
      # only for the entries this call itself moved (the script's 1), so
      # processes reconciling side by side don't run them twice.
      def bury_repeat_orphans
        buried_jobs = []
        Cogworker.config.redis do |c|
          c.lrange(RedisKeys::REPEAT_ORPHANS, 0, -1).each do |raw|
            readable = parse_hash(raw)
            job = readable || JobUtil.unparseable_job(raw, queue: nil, error: JSON::ParserError.new('unreadable'))
            job.merge!(repeat_orphan_error)
            buried = LuaScript.run(c, BURY_ORPHAN_SCRIPT, keys: [RedisKeys::REPEAT_ORPHANS, RedisKeys::DEAD],
                                                          argv: [raw, Time.now.to_f, JSON.generate(job)])
            next unless buried == 1

            buried_jobs << job if readable # it's in dead now, whatever the bookkeeping below does
            Cogworker.logger.error { "jid=#{job['jid']} orphaned too often, moved to dead" }
            buried_as_dead(c, job)
          end
        end
      ensure
        buried_jobs.each { |job| DeathNotifier.notify_orphaned(job) }
      end

      def recover_identity(identity)
        moved = requeue_in_progress(identity, if_dead_for: Cogworker.config.orphan_threshold)
        return 0 if moved.negative? # alive after all: keep its registration and last beat

        isolated("forgetting #{identity}", nil) { forget_if_empty(identity) } # its jobs are already back
        if moved.positive?
          Cogworker.logger.warn do
            "requeued #{moved} job(s) left in progress by dead process #{identity}"
          end
        end
        moved
      end

      # This process's own in-progress entries that no processor thread is
      # running — judged by the process's own in-memory record (`running:`,
      # from the Manager), never by `cogworker:workers` in Redis, which a
      # failover can lose while a long job is still running. An entry whose
      # job finished but isn't settled yet (`pending:` — its ack failed, or
      # filing its failure in retry/dead did) gets that finished here and is
      # yielded (so the caller can forget it) — never re-run. Any other
      # stray is requeued once seen on two calls in a row (the caller passes
      # back what the previous call returned): the second look rules out a
      # job caught between being fetched and being recorded as running.
      # Returns this call's strays not requeued yet.
      def reconcile(identity, previous_strays = [], running: [], pending: {}, &settled)
        key = RedisKeys.in_progress(identity)
        listed = Cogworker.config.redis { |c| c.lrange(key, 0, -1) }
        strays = listed - running
        finished, strays = strays.partition { |raw| pending.key?(raw) }
        settle_pending(identity, pending.slice(*finished), &settled)
        Cogworker.config.redis do |c|
          (strays & previous_strays).each do |raw|
            next unless LuaScript.run(c, REQUEUE_ONE_SCRIPT, keys: [key], argv: [raw, *requeue_args]) == 1

            Cogworker.logger.warn { "requeued stray in-progress job jid=#{parse_hash(raw)&.fetch('jid', nil)}" }
          end
        end
        strays - previous_strays
      end

      # Finishes each pending settlement (`raw => :ack | [set, score,
      # payload]`) that can be finished now, yielding each one done. One
      # that fails is logged and stays pending. (Filing one doesn't repeat
      # the rest of the failure path, and needn't: `stats:failed` was
      # counted when the job failed, and a terminal failure's unique lock
      # already released by UniqueJobs::ReleaseMiddleware in the chain. Nor
      # are locks extended over an interrupt's delay — at most
      # Processor::INTERRUPT_DELAY * MAX_INTERRUPTS, well inside
      # RunningLock.active_ttl.)
      def settle_pending(identity, pending)
        key = RedisKeys.in_progress(identity)
        pending.each do |raw, how|
          buried = Cogworker.config.redis do |c|
            if how == :ack
              jid = parse_hash(raw)&.fetch('jid', nil)
              LuaScript.run(c, ACK_SCRIPT, keys: [key, RedisKeys::ORPHANINGS_PREFIX + jid.to_s], argv: [raw])
              nil
            else
              set, score, payload = how
              filed = LuaScript.run(c, INTERRUPT_SCRIPT, keys: [key, set, orphanings_key(raw)],
                                                         argv: [raw, score, payload])
              filed == 1 ? filed_in_dead(c, set, payload) : nil
            end
          end
          yield raw if block_given?
          DeathNotifier.notify_failed(buried) if buried
        rescue StandardError => e
          Cogworker.logger.error do
            "still couldn't settle jid=#{parse_hash(raw)&.fetch('jid', nil)}: #{e.class}: #{e.message}"
          end
        end
      end

      # On shutdown (`Manager#requeue_unfinished`): a job that ran and
      # failed but couldn't be filed in retry/dead even now is handed over
      # to UNSETTLED with its record, so any live process can file it later
      # (`file_unsettled`) — rather than requeued with the rest, which ran a
      # `retry: false` job again on every deploy. Returns the jobs that
      # couldn't even be handed over.
      def park_unsettled(identity, pending)
        pending.reject do |raw, (set, score, payload)|
          record = JSON.generate('set' => set, 'score' => score, 'payload' => payload)
          Cogworker.config.redis do |c|
            LuaScript.run(c, PARK_UNSETTLED_SCRIPT, keys: [RedisKeys.in_progress(identity), RedisKeys::UNSETTLED],
                                                    argv: [raw, record])
          end
          true
        rescue StandardError => e
          Cogworker.logger.error do
            "couldn't hand over unsettled jid=#{parse_hash(raw)&.fetch('jid', nil)}: #{e.class}: #{e.message}"
          end
          false
        end.keys
      end

      # Files what shutting-down processes handed over in UNSETTLED, head
      # first, stopping at the first that still can't be filed (retried on
      # the next pass).
      # Death hooks run for what this call filed in dead (the script's 1).
      def file_unsettled
        buried = []
        Cogworker.config.redis do |c|
          c.lrange(RedisKeys::UNSETTLED, 0, -1).each do |record|
            entry = parse_hash(record)
            next quarantine_record(c, record) unless valid_unsettled?(entry)

            filed = LuaScript.run(c, FILE_UNSETTLED_SCRIPT,
                                  keys: [RedisKeys::UNSETTLED, orphanings_key(entry['payload'])],
                                  argv: [record, entry['set'], entry['score'], entry['payload']])
            buried << filed_in_dead(c, entry['set'], entry['payload']) if filed == 1
          end
        end
      ensure
        buried.compact.each { |payload| DeathNotifier.notify_failed(payload) }
      end

      # Jobs REQUEUE_SCRIPT had to file in dead raw (its parking list
      # unusable): swapped for a proper dead entry, and given the usual
      # terminal-failure side effects. Best-effort, per job.
      # A swap that fails (Redis away) is kept and retried on the next pass
      # (`recover_orphans`) — left alone, the raw entry stayed in dead without
      # its error, its job's locks held and its failure uncounted.
      def complete_raw_burials(raws)
        raws.each do |raw|
          readable = parse_hash(raw)
          job = (readable || {}).merge(repeat_orphan_error)
          swapped = Cogworker.config.redis do |c|
            LuaScript.run(c, SWAP_DEAD_ENTRY_SCRIPT, keys: [RedisKeys::DEAD],
                                                     argv: [raw, Time.now.to_f, JSON.generate(job)])
          end
          @raw_burials_mutex.synchronize { @pending_raw_burials.delete(raw) }
          next unless swapped == 1

          # The swap is done: the rest must not be retried (it would find
          # nothing to swap and skip the hooks), so it's best-effort.
          BestEffort.call('Orphan recovery') { Cogworker.config.redis { |c| buried_as_dead(c, job) } }
          DeathNotifier.notify_orphaned(job) if readable
        rescue StandardError => e
          @raw_burials_mutex.synchronize { @pending_raw_burials << raw unless @pending_raw_burials.include?(raw) }
          RedisErrors.report('Orphan recovery', e) { "a repeat orphan's dead entry not completed (will retry)" }
        end
      end

      def retry_raw_burials
        complete_raw_burials(@raw_burials_mutex.synchronize { @pending_raw_burials.dup })
      end

      def repeat_orphan_error
        { 'error_class' => 'Cogworker::ProcessDied', 'failed_at' => Time.now.to_f,
          'error_message' => "its process died while running it more than #{Cogworker.config.max_orphanings} times " \
                             '(killed for memory? SIGKILL?) — not retried again' }
      end

      FILEABLE_SETS = [RedisKeys::RETRY, RedisKeys::DEAD, RedisKeys::SCHEDULE].freeze

      # `set` must be one of ours to file into — not any key a damaged record
      # names (another type's, which would fail every pass at that record).
      # Just filed by this process: if that was a (readable) job into dead,
      # release its locks, as the chain would for a terminal failure, and
      # return the payload — its death hooks are due. The release is
      # best-effort: the job is in dead either way, and a raise here used
      # to cost it its hooks (the next pass's script finds nothing to file).
      def filed_in_dead(conn, set, payload)
        job = parse_hash(payload)
        return nil unless set == RedisKeys::DEAD && job

        BestEffort.call('Lock release') { JobUtil.release_terminal_locks(conn, job) }
        payload
      end

      def valid_unsettled?(entry)
        entry.is_a?(Hash) && FILEABLE_SETS.include?(entry['set']) && entry['score'].is_a?(Numeric) &&
          entry['payload'].is_a?(String)
      end

      # A record that can't be filed (unreadable, fields missing) is moved
      # out of the way — kept for a human, like KeyGuard's quarantine —
      # instead of stopping every pass at it, and everything behind it.
      def quarantine_record(conn, record)
        target = "#{KeyGuard::QUARANTINE_PREFIX}#{RedisKeys::UNSETTLED}:records"
        conn.rpush(target, record)
        conn.expire(target, KeyGuard::QUARANTINE_TTL)
        conn.lrem(RedisKeys::UNSETTLED, 1, record)
        Cogworker.logger.error { "unusable #{RedisKeys::UNSETTLED} record moved to #{target}: #{record.to_s[0, 200]}" }
      end

      # What any other terminal failure does on its way to dead: counted as
      # failed, and its `until_executed` locks released (so the entry / the
      # unique key isn't blocked until the locks' TTL). Best-effort.
      # Each step on its own, locks first: one failing (a key of the wrong
      # type) must not leave the others undone.
      def buried_as_dead(conn, job)
        JobUtil.release_terminal_locks(conn, job)
        BestEffort.call('Orphan counter') { conn.del(RedisKeys::ORPHANINGS_PREFIX + job['jid'].to_s) }
        BestEffort.call('Stats') { conn.incr(RedisKeys::STATS_FAILED) }
        BestEffort.call('Throughput') { Throughput.record('failed') }
      end

      def orphanings_key(raw)
        jid = parse_hash(raw)&.fetch('jid', nil) # (nil for an unreadable payload: an unused key then)
        "#{RedisKeys::ORPHANINGS_PREFIX}#{jid}"
      end

      def parse_hash(raw)
        value = JSON.parse(raw)
        value.is_a?(Hash) ? value : nil
      rescue JSON::ParserError
        nil
      end

      # Each source on its own: the registry set unreadable (wrong type)
      # mustn't also lose the one-off scan, and vice versa.
      def candidate_identities(scan:, report: {})
        registered = isolated('reading the in-progress registry', nil, report) do
          Cogworker.config.redis { |c| c.smembers(RedisKeys::IN_PROGRESS_IDENTITIES) }
        end
        report[:registry] = !registered.nil?
        return registered.to_a unless scan

        scanned = isolated('scanning for in-progress lists', nil, report) do
          Cogworker.config.redis do |c|
            c.scan_each(match: "#{RedisKeys::IN_PROGRESS_PREFIX}*").map { |key| key.delete_prefix(RedisKeys::IN_PROGRESS_PREFIX) }
          end
        end
        report[:scan] = !scanned.nil?
        registered.to_a | scanned.to_a
      end

      def isolated(what, fallback, report = nil)
        yield
      rescue StandardError => e
        report[:connection_lost] = true if report && RedisErrors.unavailable?(e)
        RedisErrors.report('Orphan recovery', e) { "#{what} failed" }
        fallback
      end

      def forget_if_empty(identity)
        Cogworker.config.redis do |c|
          next unless c.llen(RedisKeys.in_progress(identity)).zero?

          c.srem?(RedisKeys::IN_PROGRESS_IDENTITIES, identity)
          c.hdel(RedisKeys::LAST_BEAT, identity)
        end
      end
    end

    def retrieve_work
      keys = active_keys
      if keys.empty?
        interruptible_sleep(TIMEOUT)
        return nil
      end

      distinct = keys.uniq
      return blocking_fetch(distinct.first) if distinct.size == 1

      result = run_fetch_script(keys.shuffle.uniq + [RedisKeys.in_progress(Cogworker.identity)])
      unless result
        idle_sleep
        return nil
      end

      @idle_interval = nil
      queue_key, raw_job = result
      UnitOfWork.new(queue_key.delete_prefix(RedisKeys::QUEUE_PREFIX), raw_job)
    end

    # Atomically moves a fetched-but-unstarted job off the in-progress list
    # and back to the end of its queue that's popped next. A no-op if it's
    # no longer in progress (already requeued by `requeue_in_progress`).
    def give_back(work)
      Cogworker.config.redis do |c|
        LuaScript.run(c, REQUEUE_ONE_SCRIPT, keys: [RedisKeys.in_progress(Cogworker.identity)],
                                             argv: [work.raw_job, *self.class.requeue_args])
      end
    end

    def interrupt(work, set, score, payload)
      Cogworker.config.redis do |c|
        LuaScript.run(c, INTERRUPT_SCRIPT, keys: [RedisKeys.in_progress(Cogworker.identity), set,
                                                  self.class.orphanings_key(work.raw_job)],
                                           argv: [work.raw_job, score, payload])
      end
    end

    # Also clears the job's orphan counter: it got to finish, so whatever
    # crashes it sat through before weren't its doing (or are behind it).
    def acknowledge(work)
      jid = self.class.parse_hash(work.raw_job)&.fetch('jid', nil)
      Cogworker.config.redis do |c|
        LuaScript.run(c, ACK_SCRIPT, keys: [RedisKeys.in_progress(Cogworker.identity),
                                            RedisKeys::ORPHANINGS_PREFIX + jid.to_s],
                                     argv: [work.raw_job])
      end
    end

    private

    # With a single (unpaused) queue there's no weighting to honor, so no
    # need to poll: a blocking BLMOVE waits on the server and returns the
    # moment a job arrives, for up to TIMEOUT — same as BasicFetch's BRPOP.
    def blocking_fetch(queue_key)
      raw_job = Cogworker.config.redis do |c|
        c.blmove(queue_key, RedisKeys.in_progress(Cogworker.identity), 'RIGHT', 'LEFT', timeout: TIMEOUT)
      end
      raw_job && UnitOfWork.new(queue_key.delete_prefix(RedisKeys::QUEUE_PREFIX), raw_job)
    rescue Redis::CommandError => e
      raise unless e.message.match?(/unknown (redis )?command/i)

      raise UnsupportedError, e.message
    end

    def run_fetch_script(keys)
      Cogworker.config.redis { |c| LuaScript.run(c, FETCH_SCRIPT, keys: keys) }
    rescue Redis::CommandError => e
      raise unless e.message.match?(/unknown (redis )?command/i)

      raise UnsupportedError, e.message
    end

    # Jittered (75–100% of the interval) so a process's threads, all idle
    # at once, don't keep polling in lockstep.
    def idle_sleep
      max = Cogworker.config.fetch_idle_max_interval
      @idle_interval = @idle_interval ? [@idle_interval * 2, max].min : [EMPTY_POLL_INTERVAL, max].min
      interruptible_sleep(@idle_interval * (0.75 + (rand * 0.25)))
    end
  end
end
