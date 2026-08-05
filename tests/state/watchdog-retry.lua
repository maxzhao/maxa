-- filepath: tests/state/watchdog-retry.lua
--- Phase-2 W7 fixture: the watchdog (fake-clock driven) detects a stuck request
--- (no_message after timeout_ms), reserves ONE retry per fire (additive
--- watchdog.retry with retry_count/max_retries/reason), terminates the stuck
--- request as a terminal `timeout` failure, routes through the continuation
--- decision table (decision retry), and schedules a cancellable clock-driven
--- backoff that submits kind="retry" with retry_of = the failed request (new
--- request generation). The chain is BOUNDED (max_retries=3) and a MANUAL
--- submit resets the budget (the next stall starts again at retry_count=1).
---
--- Assertions (runtime-fixture-contract state/watchdog-retry):
---   * stuck manual submit -> no terminal; watchdog timer pending;
---   * advance(timeout) -> watchdog.retry (1/3, no_message), response.failed
---     (timeout + watchdog fields), continuation.decided (retry), backoff
---     timer pending (1s), loop stays armed (retry preserves the turn);
---   * advance(backoff) -> retry submit: new generation, intent=retry,
---     retry_of = failed request; no new user turn;
---   * three stalls -> three retries (counts 1,2,3) -> 4th call succeeds:
---     response.completed once, timer removed (fake idle);
---   * manual submit resets the budget: next stall emits watchdog.retry with
---     retry_count=1 again.
---
--- Fixture convention: prints WATCHDOG_RETRY_OK on success; throws on failure.

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
  -- Calls 1-3 stall; call 4 recovers; call 5 stalls again (manual reset check);
  -- call 6 recovers (cleanup).
  local provider, calls = stuck.make({ "stuck", "stuck", "stuck", "recovered after retries", "stuck", "cleanup done" })
  local orch = orchestrator.new({
    provider = provider,
    events = bus,
    clock = fake,
    orchestrator_config = { watchdog = { enabled = true, timeout_ms = TIMEOUT_MS, max_retries = 3 } },
  })

  -- 1) Stuck manual submit: no terminal, watchdog observing.
  local res1 = orch:submit("turn one", { provider_params = {} })
  A.check(res1.terminal_state == nil, "wdr: stuck submit has no terminal state")
  A.check(orch.session:is_busy(), "wdr: session busy while stuck")
  A.check(res1.request ~= nil, "wdr: request created")
  A.assert_eq(fake.pending(), 1, "wdr: watchdog timer pending")
  local req1 = res1.request

  -- 2) Fire #1: reserve retry 1/3 + terminal timeout + decision retry + backoff.
  fake.advance(TIMEOUT_MS)
  A.assert_eq(rec.count("watchdog.retry"), 1, "wdr: watchdog.retry once")
  local wr1
  for _, item in ipairs(rec.items) do
    if item.event == "watchdog.retry" then
      wr1 = item
      break
    end
  end
  A.check(wr1 ~= nil, "wdr: watchdog.retry payload present")
  A.assert_eq(wr1.payload.retry_count, 1, "wdr: retry_count 1")
  A.assert_eq(wr1.payload.max_retries, 3, "wdr: max_retries 3")
  A.assert_eq(wr1.payload.reason, "no_message", "wdr: reason no_message")
  A.assert_eq(wr1.payload.request_id, req1.id, "wdr: retry event carries the stuck request")
  A.assert_eq(rec.count("response.failed"), 1, "wdr: response.failed once")
  local fail1
  for _, item in ipairs(rec.items) do
    if item.event == "response.failed" then
      fail1 = item
      break
    end
  end
  A.assert_eq(fail1.payload.error.code, "timeout", "wdr: watchdog failure code timeout")
  A.check(fail1.payload.reason == nil, "wdr: not exhausted on the first fire")
  A.assert_eq(rec.count("continuation.decided"), 1, "wdr: continuation.decided once")
  local dec1
  for _, item in ipairs(rec.items) do
    if item.event == "continuation.decided" then
      dec1 = item
      break
    end
  end
  A.assert_eq(dec1.payload.decision_kind, "retry", "wdr: decision retry")
  A.assert_eq(orch.session.state, "waiting_for_user", "wdr: session waiting_for_user")
  A.assert_eq(orch.session.loop.state, "armed", "wdr: retry preserves loop armed")
  A.assert_eq(fake.pending(), 1, "wdr: backoff timer pending after fire")
  A.assert_eq(orch._watchdog:backoff_ms(), 1000, "wdr: first backoff 1s")

  -- 3) Backoff fires: retry submit -> new generation chained to the failure.
  fake.advance(orch._watchdog:backoff_ms())
  A.assert_eq(calls(), 2, "wdr: retry called the provider")
  A.assert_eq(#orch.session.requests, 2, "wdr: two requests after retry")
  local req2 = orch.session.requests[2]
  A.assert_eq(req2.intent, "retry", "wdr: retry intent")
  A.assert_eq(req2.retry_of, req1.id, "wdr: retry_of chained")
  A.assert_eq(req2.generation, 2, "wdr: new generation")
  A.check(orch.session:is_busy(), "wdr: retry request stuck -> busy")
  A.assert_eq(fake.pending(), 1, "wdr: watchdog observing the retry request")
  A.assert_eq(orch.messages:len(), 1, "wdr: no new user turn on retry")

  -- 4) Fire #2 (retry 2/3).
  fake.advance(TIMEOUT_MS)
  A.assert_eq(rec.count("watchdog.retry"), 2, "wdr: second retry event")
  local last
  for _, item in ipairs(rec.items) do
    if item.event == "watchdog.retry" then
      last = item
    end
  end
  A.assert_eq(last.payload.retry_count, 2, "wdr: retry_count 2")
  fake.advance(orch._watchdog:backoff_ms())
  A.assert_eq(calls(), 3, "wdr: second retry called the provider")
  A.assert_eq(#orch.session.requests, 3, "wdr: three requests")
  A.assert_eq(orch.session.requests[3].retry_of, req2.id, "wdr: second retry chained")

  -- 5) Fire #3 (retry 3/3) + backoff -> 4th call succeeds.
  fake.advance(TIMEOUT_MS)
  A.assert_eq(rec.count("watchdog.retry"), 3, "wdr: third retry event")
  last = nil
  for _, item in ipairs(rec.items) do
    if item.event == "watchdog.retry" then
      last = item
    end
  end
  A.assert_eq(last.payload.retry_count, 3, "wdr: retry_count 3")
  fake.advance(orch._watchdog:backoff_ms())
  A.assert_eq(calls(), 4, "wdr: third retry called the provider")
  A.assert_eq(#orch.session.requests, 4, "wdr: four requests")
  local req4 = orch.session.requests[4]
  A.assert_eq(req4.retry_of, orch.session.requests[3].id, "wdr: third retry chained")
  A.assert_eq(req4.terminal.state, "completed", "wdr: retried request completed")
  A.assert_eq(rec.count("response.completed"), 1, "wdr: response.completed once")
  A.assert_eq(rec.count("response.failed"), 3, "wdr: three watchdog failures (one per stall)")
  A.assert_eq(orch.session.state, "waiting_for_user", "wdr: session waiting_for_user after success")
  A.check(fake.idle(), "wdr: all timers removed after success")

  -- 6) Manual submit resets the budget: the next stall starts at retry_count=1.
  local res5 = orch:submit("user turn two", { provider_params = {} })
  A.check(res5.terminal_state == nil, "wdr: second manual turn stuck")
  A.assert_eq(fake.pending(), 1, "wdr: watchdog observing the manual turn")
  fake.advance(TIMEOUT_MS)
  A.assert_eq(rec.count("watchdog.retry"), 4, "wdr: fresh retry after manual reset")
  last = nil
  for _, item in ipairs(rec.items) do
    if item.event == "watchdog.retry" then
      last = item
    end
  end
  A.assert_eq(last.payload.retry_count, 1, "wdr: manual submit reset the budget (count 1)")
  A.assert_eq(last.payload.max_retries, 3, "wdr: max_retries still 3")

  -- Cleanup: let the recovery complete.
  fake.advance(orch._watchdog:backoff_ms())
  A.assert_eq(calls(), 6, "wdr: cleanup retry called the provider")
  A.assert_eq(#orch.session.requests, 6, "wdr: six requests total")
  A.check(orch.session.requests[6].terminal.state == "completed", "wdr: cleanup completed")
  A.check(fake.idle(), "wdr: idle at the end")
end

if A.ok then
  print("WATCHDOG_RETRY_OK")
else
  error("WATCHDOG_RETRY_FAILED count=" .. #A.failures)
end
