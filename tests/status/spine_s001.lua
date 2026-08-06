-- filepath: tests/status/spine_s001.lua
--- S-001 spine reducer lifecycle (phase-5 W2):
---   * counts lifecycle: request.started -> active_requests=1, terminal -> 0;
---     multi-session; teardown/reconcile zeroing
---   * counts never go negative under deliberately out-of-order events
---   * provider/model/usage/context_limit/retry/notification/terminal derivation
---   * snapshot immutability (reducer never mutates its input)
---   * revision increments per applied event, unchanged for unknown events
---   * active session identity independent of display session identity

local assert_mod = require("tests.status.lib.assert")
local spine = require("maxa.runtime.status.spine")
local events = require("maxa.runtime.events")
local status_svc = require("maxa.runtime.status")

local ctx = assert_mod.new()
local check = ctx.check
local assert_eq = ctx.assert_eq

---@private Deep equality (tables compared structurally, cycles not expected).
local function deep_eq(a, b)
  if a == b then
    return true
  end
  if type(a) ~= "table" or type(b) ~= "table" then
    return false
  end
  for k, v in pairs(a) do
    if not deep_eq(v, b[k]) then
      return false
    end
  end
  for k in pairs(b) do
    if a[k] == nil then
      return false
    end
  end
  return true
end

---@private Deep copy (for immutability pre-images).
local function copy_deep(t)
  if type(t) ~= "table" then
    return t
  end
  local out = {}
  for k, v in pairs(t) do
    out[k] = copy_deep(v)
  end
  return out
end

---@private Envelope builder.
local function ev(name, payload, at)
  return { event = name, payload = payload or {}, emitted_at = at or 0 }
end

--------------------------------------------------------------------------------
-- 1. Counts lifecycle: single request
--------------------------------------------------------------------------------
do
  local s = spine.initial_snapshot()
  s = spine.reducer(s, ev("request.started", { session_id = "s1", provider = "mock", model = "m1" }, 10))
  assert_eq(spine.counts_snapshot(s).active_requests, 1, "S001 counts: 1 active request")
  assert_eq(spine.counts_snapshot(s).running_sessions, 1, "S001 counts: 1 running session")
  assert_eq(s.active_session_id, "s1", "S001 active session id")
  assert_eq(s.provider_id, "mock", "S001 provider derived from payload")
  assert_eq(s.model, "m1", "S001 model derived from payload")

  s = spine.reducer(s, ev("response.completed", { session_id = "s1", finish_reason = "stop" }, 20))
  assert_eq(spine.counts_snapshot(s).active_requests, 0, "S001 counts: request closed")
  assert_eq(spine.counts_snapshot(s).running_sessions, 0, "S001 counts: session idle")
  assert_eq(s.terminal.state, "completed", "S001 terminal state")
  assert_eq(s.terminal.reason, "stop", "S001 terminal reason")
end

--------------------------------------------------------------------------------
-- 2. Multi-session lifecycle + teardown
--------------------------------------------------------------------------------
do
  local s = spine.initial_snapshot()
  s = spine.reducer(s, ev("request.started", { session_id = "a" }, 1))
  s = spine.reducer(s, ev("request.started", { session_id = "b" }, 2))
  assert_eq(spine.counts_snapshot(s).active_requests, 2, "S001 multi: 2 active requests")
  assert_eq(spine.counts_snapshot(s).running_sessions, 2, "S001 multi: 2 running sessions")

  s = spine.reducer(s, ev("response.completed", { session_id = "a" }, 3))
  assert_eq(spine.counts_snapshot(s).active_requests, 1, "S001 multi: a closed")
  assert_eq(spine.counts_snapshot(s).running_sessions, 1, "S001 multi: b still running")

  s = spine.reducer(s, ev("chat.closed", { session_id = "b" }, 4))
  assert_eq(spine.counts_snapshot(s).active_requests, 0, "S001 multi: teardown zero requests")
  assert_eq(spine.counts_snapshot(s).running_sessions, 0, "S001 multi: teardown zero running")
end

--------------------------------------------------------------------------------
-- 3. Counts never negative (out-of-order events)
--------------------------------------------------------------------------------
do
  local s = spine.initial_snapshot()
  -- Terminal before any request, double terminal, close without request.
  s = spine.reducer(s, ev("response.completed", { session_id = "x" }, 1))
  s = spine.reducer(s, ev("response.failed", { session_id = "x", error = { message = "boom" } }, 2))
  s = spine.reducer(s, ev("response.completed", { session_id = "x" }, 3))
  s = spine.reducer(s, ev("chat.closed", { session_id = "y" }, 4))
  s = spine.reducer(s, ev("continuation.decided", { session_id = "x", decision_kind = "terminate" }, 5))
  local c = spine.counts_snapshot(s)
  check(c.active_requests >= 0, "S001 clamp: active_requests >= 0 (got " .. c.active_requests .. ")")
  check(c.running_sessions >= 0, "S001 clamp: running_sessions >= 0 (got " .. c.running_sessions .. ")")
  check(c.warmup_tasks >= 0, "S001 clamp: warmup_tasks >= 0 (got " .. c.warmup_tasks .. ")")
end

--------------------------------------------------------------------------------
-- 4. Derived fields: usage/context_limit/retry/notification/terminal
--------------------------------------------------------------------------------
do
  local s = spine.initial_snapshot()
  s = spine.reducer(s, ev("usage.updated", { session_id = "u1", usage = { input_tokens = 10, output_tokens = 5, context_limit = 1000 } }, 1))
  assert_eq(s.usage.input_tokens, 10, "S001 usage input derived")
  assert_eq(s.usage.output_tokens, 5, "S001 usage output derived")
  assert_eq(s.context_limit, 1000, "S001 context_limit derived from usage")

  s = spine.reducer(s, ev("watchdog.retry", { session_id = "u1", retry_count = 2, max_retries = 3, reason = "no_progress" }, 2))
  assert_eq(s.retry.count, 2, "S001 retry count")
  assert_eq(s.retry.max, 3, "S001 retry max")
  assert_eq(s.retry.reason, "no_progress", "S001 retry reason")

  s = spine.reducer(s, ev("chat.soft_stop_requested", { session_id = "u1", requested = true }, 3))
  assert_eq(s.notification.message, "soft stop requested", "S001 notification set")

  s = spine.reducer(s, ev("response.failed", { session_id = "u1", error = { message = "provider down" } }, 4))
  assert_eq(s.terminal.state, "failed", "S001 terminal failed state")
  assert_eq(s.terminal.reason, "provider down", "S001 terminal failed reason")
  assert_eq(s.notification.level, "error", "S001 notification error level")

  -- Terminal cleared by the next request.started.
  s = spine.reducer(s, ev("request.started", { session_id = "u1" }, 5))
  check(next(s.terminal) == nil, "S001 terminal cleared on new request")
  check(next(s.notification) == nil, "S001 notification cleared on new request")
end

--------------------------------------------------------------------------------
-- 5. Snapshot immutability: reducer never mutates its input
--------------------------------------------------------------------------------
do
  local events_seq = {
    ev("request.started", { session_id = "imm", provider = "p", model = "m" }, 1),
    ev("response.started", { session_id = "imm" }, 2),
    ev("usage.updated", { session_id = "imm", usage = { input_tokens = 3 } }, 3),
    ev("tool_call.started", { session_id = "imm", call_id = "c1" }, 4),
    ev("tool_batch.started", { session_id = "imm", batch_id = "b1" }, 5),
    ev("watchdog.retry", { session_id = "imm", retry_count = 1, max_retries = 2 }, 6),
    ev("response.completed", { session_id = "imm", finish_reason = "stop" }, 7),
    ev("response.failed", { session_id = "imm", error = { message = "x" } }, 8),
    ev("chat.closed", { session_id = "imm" }, 9),
  }
  local s = spine.initial_snapshot()
  for _, e in ipairs(events_seq) do
    local orig = s
    local pre_image = copy_deep(s)
    s = spine.reducer(s, e)
    check(deep_eq(pre_image, orig), "S001 immutable: reducer mutated input (event " .. tostring(e.event) .. ")")
  end
end

--------------------------------------------------------------------------------
-- 6. Revision: +1 per applied event; unknown events return the same snapshot
--------------------------------------------------------------------------------
do
  local s = spine.initial_snapshot()
  assert_eq(s.revision, 0, "S001 revision initial")
  s = spine.reducer(s, ev("request.started", { session_id = "r1" }, 1))
  assert_eq(s.revision, 1, "S001 revision +1 on applied event")
  s = spine.reducer(s, ev("usage.updated", { session_id = "r1", usage = { input_tokens = 1 } }, 2))
  assert_eq(s.revision, 2, "S001 revision +1 on second event")
  local before = s
  local after = spine.reducer(s, ev("unknown.event", { foo = 1 }, 3))
  check(after == before, "S001 unknown event returns same reference")
  assert_eq(after.revision, 2, "S001 revision unchanged on unknown event")
  -- Applied events always return a new table.
  check(spine.reducer(s, ev("response.completed", { session_id = "r1" }, 4)) ~= s, "S001 applied event returns new table")
end

--------------------------------------------------------------------------------
-- 7. Tool-path count semantics + active vs display session identity
--------------------------------------------------------------------------------
do
  -- Tool path: response.completed WITH tool_calls keeps the request live; the
  -- terminal is decided by continuation.decided (wait closes it).
  local s = spine.initial_snapshot()
  s = spine.reducer(s, ev("request.started", { session_id = "t1" }, 1))
  s = spine.reducer(s, ev("response.completed", { session_id = "t1", tool_calls = { { call_id = "c1", name = "fn" } } }, 2))
  assert_eq(spine.counts_snapshot(s).active_requests, 1, "S001 tool path: request stays live")
  s = spine.reducer(s, ev("tool_batch.started", { session_id = "t1", batch_id = "b1" }, 3))
  s = spine.reducer(s, ev("continuation.decided", { session_id = "t1", decision_kind = "wait", decision_reason = "soft_stop" }, 4))
  assert_eq(spine.counts_snapshot(s).active_requests, 0, "S001 tool path: wait closes request")
  assert_eq(s.terminal.state, "completed", "S001 tool path: terminal completed")
  assert_eq(s.terminal.reason, "soft_stop", "S001 tool path: terminal reason")

  -- Active vs display identity are independent (service layer).
  local bus = events.new()
  local svc = status_svc.new({ events = bus, config = {} })
  svc:start()
  bus.emit(bus.events.request_started or "request.started", { session_id = "sA" })
  local snap = svc:snapshot()
  assert_eq(snap.active_session_id, "sA", "S001 active identity from event")
  check(snap.display_session_id == nil, "S001 display identity nil initially")
  svc:set_display_session("sB")
  snap = svc:snapshot()
  assert_eq(snap.display_session_id, "sB", "S001 display identity set")
  assert_eq(snap.active_session_id, "sA", "S001 active identity unaffected by display")
  svc:dispose()
end
