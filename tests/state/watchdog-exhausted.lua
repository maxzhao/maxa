-- filepath: tests/state/watchdog-exhausted.lua
--- Phase-2 W7 fixture: when every watchdog retry stalls, the budget is
--- exhausted and the runtime reaches a SINGLE terminal failure:
---   * watchdog.retry fires exactly max_retries times (counts 1..3);
---   * the final response.failed carries reason "watchdog_exhausted" +
---     watchdog counters (retry_count/max_retries/exhausted=true), error code
---     timeout, terminal exactly once;
---   * the continuation decision is fail(retry_budget_exhausted) (decision
---     table shares the terminal boundary with the watchdog budget);
---   * the AgentLoop is parked and the session returns to waiting_for_user
---     (Chat unlocked: a fresh MANUAL submit proceeds);
---   * the observation timer is removed (fake clock idle).
---
--- Assertions (runtime-fixture-contract state/watchdog-exhausted): bounded
--- retry chain (3 retries, generations 1..4), no watchdog.retry on exhaustion,
--- single terminal failed with watchdog_exhausted, Chat unlocked, timer
--- removed; a manual submit resets the budget (next stall retry_count=1).
---
--- Fixture convention: prints WATCHDOG_EXHAUSTED_OK on success; throws.

local assert_mod = require("tests.state.lib.assert")
local recorder = require("tests.state.lib.recorder")
local fake_clock = require("tests.state.lib.fake_clock")
local stuck = require("tests.state.lib.stuck")
local events = require("maxa.runtime.events")
local orchestrator = require("maxa.runtime.orchestrator")

local A = assert_mod.new()

local TIMEOUT_MS = 60000

do
  local fake = fake_clock.new()
  local bus = events.new()
  local rec = recorder.new()
  rec.attach(bus)
  -- Calls 1-5 stall; call 6 recovers (cleanup after the manual reset check).
  local provider, calls = stuck.make({ "stuck", "stuck", "stuck", "stuck", "stuck", "recovered" })
  local orch = orchestrator.new({
    provider = provider,
    events = bus,
    clock = fake,
    orchestrator_config = { watchdog = { enabled = true, timeout_ms = TIMEOUT_MS, max_retries = 3 } },
  })

  -- Stall 1 -> fire 1 -> retry 1/3.
  local res1 = orch:submit("doomed turn", { provider_params = {} })
  A.check(res1.terminal_state == nil, "wde: initial submit stuck")
  fake.advance(TIMEOUT_MS)
  A.assert_eq(rec.count("watchdog.retry"), 1, "wde: retry 1")
  fake.advance(orch._watchdog:backoff_ms())
  A.assert_eq(calls(), 2, "wde: retry 1 submitted")

  -- Stall 2 -> fire 2 -> retry 2/3.
  fake.advance(TIMEOUT_MS)
  A.assert_eq(rec.count("watchdog.retry"), 2, "wde: retry 2")
  fake.advance(orch._watchdog:backoff_ms())
  A.assert_eq(calls(), 3, "wde: retry 2 submitted")

  -- Stall 3 -> fire 3 -> retry 3/3.
  fake.advance(TIMEOUT_MS)
  A.assert_eq(rec.count("watchdog.retry"), 3, "wde: retry 3")
  fake.advance(orch._watchdog:backoff_ms())
  A.assert_eq(calls(), 4, "wde: retry 3 submitted")

  -- Stall 4 -> fire 4 -> EXHAUSTED (no further retry event).
  fake.advance(TIMEOUT_MS)
  A.assert_eq(rec.count("watchdog.retry"), 3, "wde: no watchdog.retry on exhaustion")
  A.assert_eq(rec.count("response.failed"), 4, "wde: one terminal failure per request")
  local last_fail
  for _, item in ipairs(rec.items) do
    if item.event == "response.failed" then
      last_fail = item
    end
  end
  A.assert_eq(last_fail.payload.reason, "watchdog_exhausted", "wde: exhausted reason")
  A.check(last_fail.payload.watchdog ~= nil, "wde: watchdog counters present")
  A.assert_eq(last_fail.payload.watchdog.retry_count, 3, "wde: retry_count 3")
  A.assert_eq(last_fail.payload.watchdog.max_retries, 3, "wde: max_retries 3")
  A.check(last_fail.payload.watchdog.exhausted == true, "wde: exhausted flag")
  A.assert_eq(last_fail.payload.error.code, "timeout", "wde: timeout code")
  A.assert_eq(rec.count("continuation.decided"), 4, "wde: four decisions")
  local last_dec
  for _, item in ipairs(rec.items) do
    if item.event == "continuation.decided" then
      last_dec = item
    end
  end
  A.assert_eq(last_dec.payload.decision_kind, "fail", "wde: decision fail")
  A.assert_eq(last_dec.payload.decision_reason, "retry_budget_exhausted", "wde: shared terminal boundary")

  -- Boundaries: 4 requests (manual + 3 retries), loop parked, Chat unlocked,
  -- observation timer removed.
  A.assert_eq(#orch.session.requests, 4, "wde: four requests (bounded)")
  for i = 2, 4 do
    A.assert_eq(orch.session.requests[i].intent, "retry", ("wde: request %d is a retry"):format(i))
    A.assert_eq(orch.session.requests[i].retry_of, orch.session.requests[i - 1].id, ("wde: retry %d chained"):format(i))
  end
  A.assert_eq(orch.session.state, "waiting_for_user", "wde: session waiting_for_user (Chat unlocked)")
  A.assert_eq(orch.session.loop.state, "waiting_for_user", "wde: loop parked")
  A.check(fake.idle(), "wde: timer removed after exhaustion")

  -- Manual submit after exhaustion works and RESETS the budget.
  local res5 = orch:submit("user takes over", { provider_params = {} })
  A.check(res5.terminal_state == nil, "wde: manual submit after exhaustion accepted (stuck)")
  A.assert_eq(fake.pending(), 1, "wde: watchdog observing the manual turn")
  fake.advance(TIMEOUT_MS)
  A.assert_eq(rec.count("watchdog.retry"), 4, "wde: fresh retry after manual submit")
  local last_wr
  for _, item in ipairs(rec.items) do
    if item.event == "watchdog.retry" then
      last_wr = item
    end
  end
  A.assert_eq(last_wr.payload.retry_count, 1, "wde: manual submit reset the budget")

  -- Cleanup: let the recovery complete.
  fake.advance(orch._watchdog:backoff_ms())
  A.assert_eq(calls(), 6, "wde: cleanup retry called the provider")
  A.check(orch.session.requests[6].terminal.state == "completed", "wde: cleanup completed")
  A.check(fake.idle(), "wde: idle at the end")
end

if A.ok then
  print("WATCHDOG_EXHAUSTED_OK")
else
  error("WATCHDOG_EXHAUSTED_FAILED count=" .. #A.failures)
end
