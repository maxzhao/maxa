-- filepath: tests/state/clock-determinism.lua
--- Phase-2 W2 headless validation: deterministic clock injection base.
--- Runtime seam under test: lua/maxa/runtime/clock.lua (contract), the
--- session `opts.clock` seam (`_clock` -> transition `at`), the events bus
--- `opts.clock` seam (envelope `emitted_at`), and the orchestrator
--- `opts.clock` forwarding.
---
--- Scenarios:
---   A. session-level determinism: full lifecycle (created->ready->busy,
---      request start/stream/terminal, waiting_for_user) plus stop/close
---      cancellation with a fake clock; exact transition `at` values; two
---      identical runs produce byte-identical transition histories.
---   B. orchestrator-level determinism: opts.clock injected into the fresh
---      session; one sync mock-provider submit; every bus envelope
---      `emitted_at` and every transition `at` equals the fake now; two runs
---      produce identical (names + emitted_at + history at) fingerprints.
---   C. fake clock unit semantics: (due, registration) firing order, cancel,
---      zero-delay run_due, reentrant scheduling within one advance.
---
--- Fixture convention: on success prints CLOCK_DETERMINISM_OK; on failure
--- throws (the runner records the failure and continues).

local assert_mod = require("tests.state.lib.assert")
local fake_clock = require("tests.state.lib.fake_clock")
local recorder = require("tests.state.lib.recorder")

local A = assert_mod.new()

local session_mod = require("maxa.runtime.session")
local events = require("maxa.runtime.events")
local orchestrator = require("maxa.runtime.orchestrator")
local protocol = require("maxa.runtime.protocol")

-------------------------------------------------------------------------------
-- A. Session-level determinism
-------------------------------------------------------------------------------
-- Run the same lifecycle twice with fresh fake clocks (same initial now) and
-- compare serialized transition histories. All ids are explicit so the
-- histories are fully reproducible.
local function session_scenario()
  local fake = fake_clock.new({ now = 1000000 })
  local bus = events.new({ clock = fake })
  local s = session_mod.new({ session_id = "s-det", project_id = "p-det", events = bus, clock = fake })
  local req, err = s:start_request({ request_id = "req-det" })
  assert(req ~= nil and err == nil, "A: start_request ok")
  fake.advance(50)
  local ok1 = session_mod.transition(req, "start", { session = s })
  fake.advance(30)
  local ok2 = session_mod.transition(req, "stream", { session = s })
  fake.advance(20)
  local ok3 = s:finish_request(req, "completed")
  assert(ok1 == true and ok2 == true and ok3 == true, "A: lifecycle transitions ok")
  return s:transition_history()
end

local h1 = session_scenario()
local h2 = session_scenario()
A.assert_eq(vim.inspect(h1), vim.inspect(h2), "A: two session runs produce identical histories")

-- Exact timestamps: ready/accept_submit at 1000000, start at 1000050,
-- stream at 1000080, request terminal + wait_for_user at 1000100.
local want_ats = { 1000000, 1000000, 1000050, 1000080, 1000100, 1000100 }
local got_ats = {}
for i, rec in ipairs(h1) do
  got_ats[i] = rec.at
end
A.assert_eq(table.concat(got_ats, ","), table.concat(want_ats, ","), "A: exact transition at sequence")
A.assert_eq(h1[1].action, "ready", "A: first record is created->ready")
A.assert_eq(h1[3].action, "start", "A: third record is request start")
A.assert_eq(h1[5].action, "terminal", "A: fifth record is request terminal")
A.assert_eq(h1[6].action, "wait_for_user", "A: sixth record is wait_for_user")

-- stop/close cancellation path: mark_cancelled must stamp via the session
-- clock too (W2 minimal fix), so the cancelled terminal `at` is deterministic.
local function cancel_scenario()
  local fake = fake_clock.new({ now = 2000000 })
  local bus = events.new({ clock = fake })
  local s = session_mod.new({ session_id = "s-det-cancel", events = bus, clock = fake })
  local req, err = s:start_request({ request_id = "req-det-cancel" })
  local b, berr = s:new_tool_batch({ batch_id = "batch-det" })
  assert(req ~= nil and b ~= nil and err == nil and berr == nil, "A: cancel setup ok")
  fake.advance(777)
  local stopped = s:stop("deterministic stop")
  assert(stopped == true, "A: stop performed")
  return s:transition_history()
end

local c1 = cancel_scenario()
local c2 = cancel_scenario()
A.assert_eq(vim.inspect(c1), vim.inspect(c2), "A: two cancel runs produce identical histories")
-- Reducer order: the stop record is appended first, then the stop effect marks
-- the active request and batch cancelled (records follow in that order).
A.assert_eq(c1[1].action, "ready", "A: cancel first record ready")
A.assert_eq(c1[2].action, "accept_submit", "A: cancel second record accept_submit")
A.assert_eq(c1[3].action, "stop", "A: stop record third")
A.assert_eq(c1[4].entity, "request", "A: cancel marks request cancelled")
A.assert_eq(c1[4].to, "cancelled", "A: request cancelled record")
A.assert_eq(c1[5].entity, "tool_batch", "A: cancel marks batch cancelled")
A.assert_eq(c1[5].to, "cancelled", "A: batch cancelled record")
for i = 3, 5 do
  A.assert_eq(c1[i].at, 2000777, "A: cancelled/stop records at 2_000_777")
end

-------------------------------------------------------------------------------
-- B. Orchestrator-level determinism (opts.clock injection + sync submit)
-------------------------------------------------------------------------------
local function orchestrator_scenario()
  local fake = fake_clock.new({ now = 3000000 })
  local bus = events.new({ clock = fake })
  local s = session_mod.new({ session_id = "s-orch-det", events = bus, clock = fake })
  local orch = orchestrator.new({
    session = s,
    provider = protocol.get(protocol.providers.mock),
    events = bus,
    clock = fake,
    model = "mock-model",
  })
  local rec = recorder.new({ skip = { "session.created" } })
  rec.attach(bus)
  local res = orch:submit("hello deterministic", {
    provider_params = { chunks = { "Hello ", "world" } },
  })
  return { fake = fake, orch = orch, rec = rec, res = res }
end

do
  local r = orchestrator_scenario()
  -- Injection assertions: the orchestrator forwarded the clock to the session
  -- and kept it for timer-driven work (watchdog W7).
  A.check(r.orch.clock == r.fake, "B: orchestrator.clock is the injected clock")
  A.check(r.orch.session._clock == r.fake, "B: session._clock is the injected clock")
  A.assert_eq(r.res.terminal_state, "completed", "B: sync submit terminal_state")

  -- Bus events: exact order; every envelope emitted_at equals the fake now.
  local want = {
    "request.submitted",
    "request.started",
    "response.started",
    "message.delta",
    "message.delta",
    "response.completed",
  }
  A.assert_eq(r.rec.names_concat(), table.concat(want, ","), "B: bus event order")
  for i, item in ipairs(r.rec.items) do
    A.assert_eq(item.envelope.emitted_at, 3000000, "B: event " .. i .. " emitted_at deterministic")
  end

  -- Transition stamps: request terminal + session wait_for_user at fake now.
  local req = r.orch.session.requests[1]
  A.check(req ~= nil and req.terminal ~= nil, "B: request has terminal record")
  A.assert_eq(req.terminal and req.terminal.at, 3000000, "B: request terminal at deterministic")
  local hist_ats = {}
  for i, rec_ in ipairs(r.orch.session:transition_history()) do
    hist_ats[i] = rec_.at
  end
  -- W4: the orchestrator drives the request entity through its canonical
  -- lifecycle (submitted -> starting -> streaming) via mark_started, so a full
  -- text-only submit records (ready, accept_submit, start, stream, terminal,
  -- wait_for_user) — six records, all at the fake now.
  A.assert_eq(
    table.concat(hist_ats, ","),
    "3000000,3000000,3000000,3000000,3000000,3000000",
    "B: history at sequence (ready,accept_submit,start,stream,terminal,wait_for_user)"
  )
end

-- Two full runs produce identical fingerprints: names + emitted_at + history at.
local function fingerprint(r)
  local parts = { r.rec.names_concat() }
  local ats = {}
  for i, item in ipairs(r.rec.items) do
    ats[i] = item.envelope.emitted_at
  end
  parts[#parts + 1] = table.concat(ats, ",")
  local h = {}
  for i, rec_ in ipairs(r.orch.session:transition_history()) do
    h[i] = rec_.at
  end
  parts[#parts + 1] = table.concat(h, ",")
  return table.concat(parts, "|")
end
A.assert_eq(
  fingerprint(orchestrator_scenario()),
  fingerprint(orchestrator_scenario()),
  "B: two orchestrator runs produce identical fingerprints"
)

-------------------------------------------------------------------------------
-- C. Fake clock unit semantics
-------------------------------------------------------------------------------
do
  local fired = {}
  local fake = fake_clock.new({ now = 100 })
  fake.schedule(100, function()
    fired[#fired + 1] = "c1"
  end)
  fake.schedule(50, function()
    fired[#fired + 1] = "c2"
  end)
  fake.schedule(50, function()
    fired[#fired + 1] = "c3"
  end)
  A.assert_eq(fake.pending(), 3, "C: three pending timers")
  A.assert_eq(fake.remaining(), 50, "C: next due in 50ms")
  fake.advance(50)
  A.assert_eq(table.concat(fired, ","), "c2,c3", "C: same-due timers fire in registration order")
  A.assert_eq(fake.now_ms(), 150, "C: now advanced to 150")
  fake.advance(50)
  A.assert_eq(table.concat(fired, ","), "c2,c3,c1", "C: later timer fired at its due time")
  A.check(fake.idle(), "C: idle after all timers fired")

  -- cancel prevents firing.
  local fake2 = fake_clock.new()
  local cancelled = false
  local h = fake2.schedule(10, function()
    cancelled = true
  end)
  fake2.cancel_timer(h)
  fake2.advance(100)
  A.check(not cancelled, "C: cancelled timer never fires")
  A.assert_eq(fake2.fired_count(), 0, "C: no callbacks fired after cancel")

  -- zero-delay timer fires via run_due without advancing the clock.
  local fake3 = fake_clock.new()
  local z = 0
  fake3.schedule(0, function()
    z = z + 1
  end)
  A.assert_eq(fake3.now_ms(), 0, "C: now unchanged before run_due")
  A.assert_eq(fake3.run_due(), 1, "C: zero-delay fired by run_due")
  A.assert_eq(z, 1, "C: zero-delay callback ran")

  -- reentrant scheduling: a zero-delay timer scheduled from a fired callback
  -- is due at the current virtual now and fires within the same advance; a
  -- positive-delay reentrant timer stays pending until the next advance.
  local fake4 = fake_clock.new()
  local order = {}
  fake4.schedule(10, function()
    order[#order + 1] = "outer"
    fake4.schedule(0, function()
      order[#order + 1] = "inner0"
    end) -- due now (20) <= 20: fires in the same advance
    fake4.schedule(2, function()
      order[#order + 1] = "inner2"
    end) -- due 22 > 20: pending until the next advance
  end)
  fake4.advance(20)
  A.assert_eq(table.concat(order, ","), "outer,inner0", "C: reentrant zero-delay fires in same advance")
  A.assert_eq(fake4.pending(), 1, "C: positive-delay reentrant stays pending")
  fake4.advance(2)
  A.assert_eq(table.concat(order, ","), "outer,inner0,inner2", "C: pending reentrant fires on next advance")
  A.assert_eq(fake4.now_ms(), 22, "C: advance moved now")
end

-------------------------------------------------------------------------------
-- D. Import-guard (fixture-local, in addition to the runner-level guard)
-------------------------------------------------------------------------------
do
  local guard = require("maxa.runtime.guard")
  local gok, gerr = pcall(guard.assert_no_forbidden)
  A.check(gok, "D: import-guard no legacy families (" .. tostring(gerr) .. ")")
end

if A.ok then
  print("CLOCK_DETERMINISM_OK")
else
  error("CLOCK_DETERMINISM_FAILED count=" .. #A.failures)
end
