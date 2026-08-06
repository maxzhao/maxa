-- filepath: tests/events/event-id-deterministic.lua
--- W1 event_id determinism: same payload + same session twice yields distinct
--- event_ids with a stable "<session>:<sequence>" format; an explicit
--- payload.event_id wins; session-less events use the "global" namespace.

local assert_mod = require("tests.state.lib.assert")
local events = require("maxa.runtime.events")

local ctx = assert_mod.new()
local bus = events.new()

local e1 = bus.emit("response.completed", { session_id = "sess-det", generation = 1 })
local e2 = bus.emit("response.completed", { session_id = "sess-det", generation = 1 })
ctx.assert_eq(e1.event_id, "sess-det:1", "first event_id")
ctx.assert_eq(e2.event_id, "sess-det:2", "second event_id differs by sequence")
ctx.check(e1.event_id:match("^sess%-det:%d+$") ~= nil, "event_id format <session>:<sequence> (e1)")
ctx.check(e2.event_id:match("^sess%-det:%d+$") ~= nil, "event_id format <session>:<sequence> (e2)")
ctx.check(e1.event_id ~= e2.event_id, "distinct event_ids for distinct sequences")

-- Explicit external event_id (replay scenario) wins.
local ext = bus.emit("history.saved", { session_id = "sess-det", event_id = "ext-stable-42" })
ctx.assert_eq(ext.event_id, "ext-stable-42", "explicit payload.event_id adopted")

-- No session: global namespace, still deterministic format.
local g1 = bus.emit("chat.closed", {})
local g2 = bus.emit("chat.closed", {})
ctx.assert_eq(g1.event_id, "global:4", "global event_id g1")
ctx.assert_eq(g2.event_id, "global:5", "global event_id g2")

-- session_seq increments for the explicit-id event too (still one per emit).
ctx.assert_eq(ext.session_seq, 3, "explicit event_id keeps session_seq")

if not ctx.ok then
  error("event-id-deterministic: " .. table.concat(ctx.failures, "; "), 0)
end
print("EVENT_ID_DETERMINISTIC_OK")
