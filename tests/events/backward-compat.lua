-- filepath: tests/events/backward-compat.lua
--- W1 backward compatibility: the legacy 2-arg emit(payload) plus
--- on/once/count/clear behave exactly as before on the singleton bus; new APIs
--- work on the singleton too; instances are isolated from each other and from
--- the singleton (instance-level idempotency/reducer state).

local assert_mod = require("tests.state.lib.assert")
local events = require("maxa.runtime.events")

local ctx = assert_mod.new()

-- --- Singleton legacy API ---
events.clear() -- cold start for the singleton
ctx.assert_eq(events.count("request.submitted"), 0, "singleton starts empty after clear")

local calls = 0
local cb = function()
  calls = calls + 1
end
events.on("request.submitted", cb)
events.on("request.submitted", cb) -- idempotent registration
ctx.assert_eq(events.count("request.submitted"), 1, "same (event, cb) registered once")

local once_calls = 0
events.once("request.submitted", function()
  once_calls = once_calls + 1
end)
ctx.assert_eq(events.count("request.submitted"), 2, "once subscriber counted")

local legacy_env = events.emit("request.submitted", { session_id = "sess-legacy" })
ctx.assert_eq(legacy_env.event, "request.submitted", "legacy envelope.event")
ctx.assert_eq(legacy_env.sequence, 1, "legacy sequence starts at 1 after clear")
ctx.assert_eq(legacy_env.payload.session_id, "sess-legacy", "legacy payload passthrough")
ctx.check(type(legacy_env.emitted_at) == "number", "legacy emitted_at is numeric")
ctx.assert_eq(calls, 1, "legacy emit dispatches once")
ctx.assert_eq(once_calls, 1, "once subscriber fires exactly once")
events.emit("request.submitted", { session_id = "sess-legacy" })
ctx.assert_eq(once_calls, 1, "once subscriber does not re-fire")
ctx.assert_eq(calls, 2, "regular subscriber keeps firing")

local off = events.on("chat.closed", function() end)
off()
ctx.assert_eq(events.count("chat.closed"), 0, "unsubscribe removes the listener")

-- --- Singleton new APIs ---
local singleton_reducer_count = 0
events.register_reducer(function()
  singleton_reducer_count = singleton_reducer_count + 1
end)
events.emit("history.saved", { session_id = "sess-legacy2", save_id = "s1" })
ctx.assert_eq(singleton_reducer_count, 1, "singleton reducer runs on emit")

local applied = events.replay({ { event_id = "legacy-replay-1", event = "history.saved", type = "history.saved", sequence = 2, timestamp = 1, payload = {} } })
ctx.assert_eq(applied, 1, "singleton replay applies a fresh id")
ctx.assert_eq(singleton_reducer_count, 2, "singleton reducer runs during replay")
ctx.check(events.seen_event_ids()["legacy-replay-1"] == true, "singleton seen table updated")

-- --- Instance isolation ---
local busA = events.new()
local busB = events.new()
local a_count = 0
local b_count = 0
busA.register_reducer(function()
  a_count = a_count + 1
end)
busB.register_reducer(function()
  b_count = b_count + 1
end)
busA.emit("response.completed", { session_id = "sess-iso-a" })
busB.emit("response.completed", { session_id = "sess-iso-b" })
ctx.assert_eq(a_count, 1, "busA reducer sees only busA emits")
ctx.assert_eq(b_count, 1, "busB reducer sees only busB emits")
ctx.check(busA.seen_event_ids()["sess-iso-a:1"] == true, "busA idempotency is instance-local")
ctx.check(busB.seen_event_ids()["sess-iso-a:1"] == nil, "busB never sees busA event ids")

events.clear() -- leave the singleton clean for any later consumer

if not ctx.ok then
  error("backward-compat: " .. table.concat(ctx.failures, "; "), 0)
end
print("BACKWARD_COMPAT_OK")
