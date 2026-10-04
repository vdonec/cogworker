-- KEYS[1] = periodic:running:<pjid>
-- KEYS[2] = periodic:last_slot:<pjid>
-- KEYS[3] = periodic:lock:<pjid>:<slot>
-- ARGV[1] = slot (epoch int)
-- ARGV[2] = unique mode ("until_executed" or "")
-- ARGV[3] = lock TTL (seconds)
-- ARGV[4] = jid the caller will push this slot's job under
-- ARGV[5] = running-lock TTL (seconds)
--
-- Returns {1, <previous last_slot, or "" if none>} if this call won the
-- claim for this slot (the caller should enqueue the job — and, if that
-- fails, roll the claim back with ROLLBACK_SCRIPT using that previous
-- value), 2 if blocked by the entry's running lock, 0 otherwise. Composes two guards: `last_slot` stops a
-- process re-firing the same (or an earlier) slot on a later tick, and the
-- NX lock breaks the narrow race where two processes both pass the
-- `last_slot` check before either has written it back.
--
-- For `until_executed`, the running lock is written here, in the same
-- atomic step as the claim and before the job exists anywhere — see
-- Periodic::RunningLock for why it must never be written after the push.
-- Blocked by a run still holding the entry's lock: a distinct 2, so the
-- caller can retry the slot briefly — the lock may only be waiting for a
-- release delayed by an outage (see Ticker::BLOCKED_GRACE).
if ARGV[2] == "until_executed" and redis.call("GET", KEYS[1]) then
  return 2
end

local previous = redis.call("GET", KEYS[2])
local last = tonumber(previous or "0")
if tonumber(ARGV[1]) <= last then
  return 0
end

if not redis.call("SET", KEYS[3], "1", "NX", "EX", ARGV[3]) then
  return 0
end

redis.call("SET", KEYS[2], ARGV[1])
if ARGV[2] == "until_executed" then
  redis.call("SET", KEYS[1], ARGV[4], "EX", ARGV[5])
end
return {1, previous or ""}
