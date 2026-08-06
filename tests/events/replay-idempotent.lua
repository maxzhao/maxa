-- filepath: tests/events/replay-idempotent.lua
--- W1 replay idempotency: the same event_id applied twice through replay runs
--- the reducer exactly once; observers never run by default (no side effects);
--- seen_event_ids() exposes the idempotency table; clear() resets it.

local assert_mod = require("tests.state.lib.assert")
local events = require("maxa.runtime.events")

local ctx = assert_mod.new()
local bus = events.new()

local reducer_count = 0
bus.register_reducer(function(payload, envelope)
  reducer_count = reducer_count + 1
end)

local observer_ran = false
bus.on("response.completed", function()
  observer_ran = true
end)

local ev1 = { event_id = "replay-1", event = "response.completed", type = "response.completed", sequence = 1, timestamp = 10, payload = { session_id = "sess-r" } }
local ev2 = { event_id = "replay-2", event = "response.completed", type = "response.completed", sequence = 2, timestamp = 11, payload = { session_id = "sess-r" } }

-- First replay: both applied, reducer runs twice, observers stay silent.
local applied1 = bus.replay({ ev1, ev2 })
ctx.assert_eq(applied1, 2, "first replay applies both events")
ctx.assert_eq(reducer_count, 2, "reducer ran once per event")
ctx.check(not observer_ran, "observers not executed on default replay")

-- Second replay of the same stream: everything skipped.
local applied2 = bus.replay({ ev1, ev2 })
ctx.assert_eq(applied2, 0, "second replay applies nothing")
ctx.assert_eq(reducer_count, 2, "reducer did not re-run for seen ids")

-- opts.observers=true runs observers for unseen ids only.
local ev3 = { event_id = "replay-3", event = "response.completed", type = "response.completed", sequence = 3, timestamp = 12, payload = {} }
local applied3 = bus.replay({ ev3 }, { observers = true })
ctx.assert_eq(applied3, 1, "observers-opt replay applies the fresh event")
ctx.check(observer_ran, "observers run when explicitly enabled")
ctx.assert_eq(reducer_count, 3, "reducer ran for the fresh event too")

-- seen_event_ids() returns a copy with every applied id.
local seen = bus.seen_event_ids()
ctx.check(seen["replay-1"] == true, "seen contains replay-1")
ctx.check(seen["replay-2"] == true, "seen contains replay-2")
ctx.check(seen["replay-3"] == true, "seen contains replay-3")
local before = next(seen)
seen[before] = nil -- mutating the copy must not affect the bus
ctx.check(bus.seen_event_ids()[before] == true, "copy mutation does not touch the bus")

-- clear() wipes the idempotency table and resets the sequence.
bus.clear()
local seen_after = bus.seen_event_ids()
ctx.check(next(seen_after) == nil, "clear() empties the idempotency table")
local fresh = bus.emit("response.completed", { session_id = "sess-r" })
ctx.assert_eq(fresh.sequence, 1, "sequence resets after clear()")

if not ctx.ok then
  error("replay-idempotent: " .. table.concat(ctx.failures, "; "), 0)
end
print("REPLAY_IDEMPOTENT_OK")
