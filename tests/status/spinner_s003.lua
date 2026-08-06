-- filepath: tests/status/spinner_s003.lua
--- S-003 spinner phase determinism (phase-5 W2):
---   * debounce: request_start only after `delay_ms` elapsed since
---     request.started (fake clock: < delay -> idle, >= delay -> request_start)
---   * precedence: terminal > tool_exec > retry > tool_args > response_start >
---     request_start > idle
---   * retry phase cleared by the next request.started
---   * service integration: spinner_phase() derives from the same snapshot

local assert_mod = require("tests.status.lib.assert")
local spine = require("maxa.runtime.status.spine")
local events = require("maxa.runtime.events")
local fake_clock = require("tests.status.lib.fake_clock")
local status_svc = require("maxa.runtime.status")

local ctx = assert_mod.new()
local assert_eq = ctx.assert_eq

---@private Envelope builder with explicit emitted_at.
local function ev(name, payload, at)
  return { event = name, payload = payload or {}, emitted_at = at or 0 }
end

-- Debounce: request_start phase only after delay_ms.
do
  local s = spine.initial_snapshot()
  s = spine.reducer(s, ev("request.started", { session_id = "p1" }, 0))
  assert_eq(spine.spinner_phase(s, 0, 300), "idle", "S003 debounce: t=0 idle")
  assert_eq(spine.spinner_phase(s, 299, 300), "idle", "S003 debounce: t=299 idle")
  assert_eq(spine.spinner_phase(s, 300, 300), "request_start", "S003 debounce: t=300 request_start")
  assert_eq(spine.spinner_phase(s, 5000, 300), "request_start", "S003 debounce: t=5000 request_start")

  -- Custom delay from config surface.
  assert_eq(spine.spinner_phase(s, 199, 200), "idle", "S003 debounce: custom delay boundary-1")
  assert_eq(spine.spinner_phase(s, 200, 200), "request_start", "S003 debounce: custom delay boundary")
end

-- Precedence chain (single session).
do
  local s = spine.initial_snapshot()
  s = spine.reducer(s, ev("request.started", { session_id = "p1" }, 0))
  s = spine.reducer(s, ev("response.started", { session_id = "p1" }, 300))
  assert_eq(spine.spinner_phase(s, 400, 300), "response_start", "S003 precedence: response_start > request_start")

  s = spine.reducer(s, ev("tool_call.started", { session_id = "p1", call_id = "c1" }, 400))
  assert_eq(spine.spinner_phase(s, 500, 300), "tool_args", "S003 precedence: tool_args > response_start")

  s = spine.reducer(s, ev("tool_batch.started", { session_id = "p1", batch_id = "b1" }, 500))
  assert_eq(spine.spinner_phase(s, 600, 300), "tool_exec", "S003 precedence: tool_exec > tool_args")

  -- watchdog.retry while tool_exec is active keeps tool_exec (higher priority).
  s = spine.reducer(s, ev("watchdog.retry", { session_id = "p1", retry_count = 1, max_retries = 2 }, 600))
  assert_eq(spine.spinner_phase(s, 700, 300), "tool_exec", "S003 precedence: tool_exec > retry")
end

-- retry beats tool_args when no tool_exec happened.
do
  local s = spine.initial_snapshot()
  s = spine.reducer(s, ev("request.started", { session_id = "p2" }, 0))
  s = spine.reducer(s, ev("tool_call.started", { session_id = "p2", call_id = "c1" }, 100))
  s = spine.reducer(s, ev("watchdog.retry", { session_id = "p2", retry_count = 1, max_retries = 2 }, 200))
  assert_eq(spine.spinner_phase(s, 300, 300), "retry", "S003 precedence: retry > tool_args")

  -- terminal beats everything.
  s = spine.reducer(s, ev("response.failed", { session_id = "p2", error = { message = "x" } }, 300))
  assert_eq(spine.spinner_phase(s, 400, 300), "terminal", "S003 precedence: terminal highest")
end

-- retry phase is cleared by the next request.started.
do
  local s = spine.initial_snapshot()
  s = spine.reducer(s, ev("request.started", { session_id = "p3" }, 0))
  s = spine.reducer(s, ev("watchdog.retry", { session_id = "p3", retry_count = 1, max_retries = 2 }, 100))
  assert_eq(spine.spinner_phase(s, 300, 300), "retry", "S003 retry phase active")
  s = spine.reducer(s, ev("request.started", { session_id = "p3" }, 500))
  assert_eq(spine.spinner_phase(s, 800, 300), "request_start", "S003 retry cleared by new request")
end

-- Empty / idle snapshots.
do
  assert_eq(spine.spinner_phase(spine.initial_snapshot(), 0, 300), "idle", "S003 idle: empty snapshot")
  local s = spine.initial_snapshot()
  s = spine.reducer(s, ev("response.completed", { session_id = "gone" }, 10))
  assert_eq(spine.spinner_phase(s, 1000, 300), "terminal", "S003 terminal after close")
end

-- Service integration with a deterministic fake clock.
do
  local fake = fake_clock.new({ now = 0 })
  local bus = events.new({ clock = fake })
  local svc = status_svc.new({ events = bus, config = { ui = { spinner_delay = 300 } } })
  svc:start()
  bus.emit("request.started", { session_id = "svc1" })
  assert_eq(svc:spinner_phase(fake.now_ms()), "idle", "S003 service: debounce idle")
  fake.advance(300)
  assert_eq(svc:spinner_phase(fake.now_ms()), "request_start", "S003 service: after delay request_start")
  bus.emit("response.started", { session_id = "svc1" })
  assert_eq(svc:spinner_phase(fake.now_ms()), "response_start", "S003 service: response_start")
  svc:dispose()
end
