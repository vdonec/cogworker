# frozen_string_literal: true

module Cogworker
  # Every Redis key name/namespace this gem reads or writes, in one place —
  # the client (push), the server (processor/scheduler/heartbeat/periodic
  # ticker), and the Web UI all read and write the exact same keys through
  # these constants/methods rather than retyping the literal, so a typo
  # can't silently create a second, disconnected copy of a set/list/hash
  # that nothing else reads.
  module RedisKeys
    QUEUE_PREFIX = 'cogworker:queue:'
    IN_PROGRESS_PREFIX = 'cogworker:inprogress:'
    # Every identity that has (or may have) an in-progress list — what
    # orphan recovery walks instead of SCANning the whole keyspace.
    IN_PROGRESS_IDENTITIES = 'cogworker:inprogress_identities'
    # identity => Redis server time (epoch seconds) of its last heartbeat.
    # No TTL, unlike `process(identity)`: it's what tells "dead for a
    # while" apart from "missed a few beats" (Config#orphan_threshold).
    LAST_BEAT = 'cogworker:last_beat'
    QUEUES = 'cogworker:queues'
    SCHEDULE = 'cogworker:schedule'
    RETRY = 'cogworker:retry'
    DEAD = 'cogworker:dead'
    PROCESSES = 'cogworker:processes'
    PAUSED_QUEUES = 'cogworker:paused_queues'
    STATS_PROCESSED = 'cogworker:stats:processed'
    STATS_FAILED = 'cogworker:stats:failed'
    PERIODIC_SCHEDULE = 'periodic:schedule'
    PERIODIC_DISABLED = 'periodic:disabled'

    module_function

    def queue(name) = "#{QUEUE_PREFIX}#{name}"
    def job_attempts(jid) = "cogworker:job_attempts:#{jid}"
    def process(identity) = "cogworker:process:#{identity}"
    def workers(identity) = "cogworker:workers:#{identity}"
    def in_progress(identity) = "#{IN_PROGRESS_PREFIX}#{identity}"
    def signal(identity) = "cogworker:signal:#{identity}"
    def periodic_running(pjid) = "periodic:running:#{pjid}"
    def periodic_last_slot(pjid) = "periodic:last_slot:#{pjid}"
    def periodic_lock(pjid, slot) = "periodic:lock:#{pjid}:#{slot}"
    def unique_lock(digest) = "cogworker:unique:#{digest}"
    def throughput_bucket(hour) = "cogworker:throughput:#{hour}"
    def history_daily_bucket(day) = "cogworker:history:daily:#{day}"
  end
end
