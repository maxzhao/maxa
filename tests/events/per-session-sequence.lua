-- filepath: tests/events/per-session-sequence.lua
--- W1 per-session sub-sequences: two sessions advance independently while the
--- global sequence stays strictly monotonic across interleaved emits.

local assert_mod = require("tests.state.lib.assert")
local events = require("maxa.runtime.events")

local ctx = assert_mod.new()
local bus = events.new()

local a_seqs = {}
local b_seqs = {}
local global_seqs = {}

-- Interleave sessions a and b: a1, b1, a2, b2, a3, b3.
for i = 1, 3 do
  local a = bus.emit("request.submitted", { session_id = "sess-a", request_id = "a" .. i })
  a_seqs[i] = a.session_seq
  global_seqs[#global_seqs + 1] = a.sequence
  local b = bus.emit("message.delta", { session_id = "sess-b", request_id = "b" .. i })
  b_seqs[i] = b.session_seq
  global_seqs[#global_seqs + 1] = b.sequence
end

ctx.assert_eq(a_seqs[1], 1, "sess-a first session_seq")
ctx.assert_eq(a_seqs[2], 2, "sess-a second session_seq")
ctx.assert_eq(a_seqs[3], 3, "sess-a third session_seq")
ctx.assert_eq(b_seqs[1], 1, "sess-b first session_seq")
ctx.assert_eq(b_seqs[2], 2, "sess-b second session_seq")
ctx.assert_eq(b_seqs[3], 3, "sess-b third session_seq")

-- Global sequence strictly monotonic over all six emits (1..6 in order).
for i = 1, #global_seqs do
  ctx.assert_eq(global_seqs[i], i, "global sequence position " .. i)
end

if not ctx.ok then
  error("per-session-sequence: " .. table.concat(ctx.failures, "; "), 0)
end
print("PER_SESSION_SEQUENCE_OK")
