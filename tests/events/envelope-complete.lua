-- filepath: tests/events/envelope-complete.lua
--- W1 envelope completeness: every contract field is present and carries the
--- expected value; legacy fields (event/emitted_at) survive; timestamp follows
--- the injected deterministic clock.

local assert_mod = require("tests.state.lib.assert")
local fake_clock_mod = require("tests.state.lib.fake_clock")
local events = require("maxa.runtime.events")

local ctx = assert_mod.new()
local fake = fake_clock_mod.new({ now = 5000 })
local bus = events.new({ clock = fake })

local payload = {
  project_id = "proj-1",
  session_id = "sess-1",
  request_id = "req-1",
  turn_id = "turn-1",
  tool_batch_id = "batch-1",
  tool_call_id = "call-1",
  task_id = "task-1",
  view_id = "view-1",
  generation = 3,
  reason = "manual",
  note = "extra payload data",
}

local envelope = bus.emit("request.started", payload)

-- Legacy fields preserved verbatim.
ctx.assert_eq(envelope.event, "request.started", "envelope.event legacy field")
ctx.assert_eq(envelope.emitted_at, 5000, "envelope.emitted_at legacy field")
-- New contract fields.
ctx.assert_eq(envelope.type, "request.started", "envelope.type")
ctx.assert_eq(envelope.timestamp, 5000, "envelope.timestamp")
ctx.assert_eq(envelope.event_id, "sess-1:1", "envelope.event_id")
ctx.assert_eq(envelope.sequence, 1, "envelope.sequence")
ctx.assert_eq(envelope.session_seq, 1, "envelope.session_seq")
ctx.assert_eq(envelope.project_id, "proj-1", "envelope.project_id")
ctx.assert_eq(envelope.session_id, "sess-1", "envelope.session_id")
ctx.assert_eq(envelope.request_id, "req-1", "envelope.request_id")
ctx.assert_eq(envelope.turn_id, "turn-1", "envelope.turn_id")
ctx.assert_eq(envelope.tool_batch_id, "batch-1", "envelope.tool_batch_id")
ctx.assert_eq(envelope.tool_call_id, "call-1", "envelope.tool_call_id")
ctx.assert_eq(envelope.task_id, "task-1", "envelope.task_id")
ctx.assert_eq(envelope.view_id, "view-1", "envelope.view_id")
ctx.assert_eq(envelope.generation, 3, "envelope.generation")
ctx.assert_eq(envelope.reason, "manual", "envelope.reason")
ctx.assert_eq(envelope.payload, payload, "envelope.payload identity")

-- A payload without identity still yields a complete envelope: identity keys
-- are present (nil) and the event_id falls back to the global namespace.
local bare = bus.emit("history.saved", { save_id = "s" })
ctx.assert_eq(bare.event_id, "global:2", "bare envelope event_id global fallback")
for _, key in ipairs({ "project_id", "session_id", "request_id", "turn_id", "tool_batch_id", "tool_call_id", "task_id", "view_id", "generation", "reason" }) do
  ctx.check(bare[key] == nil, "bare envelope identity field " .. key .. " is nil")
end
ctx.assert_eq(bare.session_seq, nil, "bare envelope session_seq is nil")

-- Envelope must not be mutated by the caller afterwards (payload reference).
ctx.assert_eq(envelope.payload.note, "extra payload data", "payload passthrough")

if not ctx.ok then
  error("envelope-complete: " .. table.concat(ctx.failures, "; "), 0)
end
print("ENVELOPE_COMPLETE_OK")
