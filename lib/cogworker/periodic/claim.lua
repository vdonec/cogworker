-- KEYS[1] = periodic:running:<pjid>
-- KEYS[2] = periodic:last_slot:<pjid>
-- KEYS[3] = periodic:lock:<pjid>:<slot>
-- ARGV[1] = slot (epoch int)
-- ARGV[2] = unique mode ("until_executed" or "")
-- ARGV[3] = lock TTL (seconds)
--
-- Returns 1 if this call won the claim for this slot (the caller should
-- enqueue the job), 0 otherwise. Composes two guards: `last_slot` stops a
-- process re-firing the same (or an earlier) slot on a later tick, and the
-- NX lock breaks the narrow race where two processes both pass the
-- `last_slot` check before either has written it back.
if ARGV[2] == "until_executed" and redis.call("GET", KEYS[1]) then
  return 0
end

local last = tonumber(redis.call("GET", KEYS[2]) or "0")
if tonumber(ARGV[1]) <= last then
  return 0
end

if not redis.call("SET", KEYS[3], "1", "NX", "EX", ARGV[3]) then
  return 0
end

redis.call("SET", KEYS[2], ARGV[1])
return 1
