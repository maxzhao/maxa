-- filepath: tests/state/watchdog-softstop-suppressed.lua
--- Phase-2 W7 fixture: a pending soft-stop drain suppresses the watchdog (W6
--- semantics: the drain is the user's boundary, not a stall). While the soft
--- stop is armed the observation timer is paused (fake clock: advancing far
--- beyond the timeout triggers nothing and never terminates the request);
--- toggling the soft stop OFF resumes a fresh observation window, after which
--- the watchdog fires normally (retry chain) — proving pause/resume compose
--- without firing into the drain.
---
--- Assertions (runtime-fixture-contract state/watchdog-softstop-suppressed):
---   * async stuck submit -> busy, watchdog observing;
---   * soft_stop accepted -> watchdog paused, timer removed;
---   * advance(3x timeout) -> NO watchdog.retry / response.failed (suppressed);
---   * soft_stop toggle-off -> watchdog resumed (fresh window, timer pending);
---   * advance(timeout) -> watchdog.retry (1/3) + response.failed + decision
---     retry (the toggled-off soft stop was consumed by the user, so no
---     chat.soft_stop_completed at the drain);
---   * backoff -> retry submits and completes (timer removed).
---
--- Fixture convention: prints WATCHDOG_SOFTSTOP_SUPPRESSED_OK on success; throws.

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
  -- Call 1 stalls (the watched request); call 2 recovers (retry cleanup).
  local provider, calls = stuck.make({ "stuck", "recovered after soft stop" })
  local orch = orchestrator.new({
    provider = provider,
    events = bus,
    clock = fake,
    orchestrator_config = { watchdog = { enabled = true, timeout_ms = TIMEOUT_MS, max_retries = 3 } },
  })

  -- 1) Async stuck submit: request in flight, watchdog observing.
  local res = orch:submit("drain turn", { async = true })
  A.check(res.async == true, "wss: async submit")
  A.check(orch.session:is_busy(), "wss: session busy")
  A.assert_eq(fake.pending(), 1, "wss: watchdog observing")

  -- 2) Soft stop accepted -> watchdog paused (timer removed).
  local ss1 = orch:soft_stop()
  A.check(ss1.accepted == true, "wss: soft stop accepted")
  A.check(orch._soft_stop_requested == true, "wss: soft stop armed")
  A.check(orch._watchdog.pauses.soft_stop ~= nil, "wss: watchdog paused for soft stop")
  A.check(fake.idle(), "wss: observation timer removed during the drain")

  -- 3) Far beyond the timeout: suppressed (no fire, no termination).
  fake.advance(TIMEOUT_MS * 3)
  A.assert_eq(rec.count("watchdog.retry"), 0, "wss: no retry during the drain")
  A.assert_eq(rec.count("response.failed"), 0, "wss: no terminal failure during the drain")
  A.check(orch.session:is_busy(), "wss: request still in flight (drain not a stall)")

  -- 4) Toggle-off resumes the watchdog with a fresh window.
  local ss2 = orch:soft_stop()
  A.check(ss2.toggled_off == true, "wss: repeat soft stop toggles off")
  A.check(orch._soft_stop_requested == false, "wss: soft stop cleared")
  A.check(next(orch._watchdog.pauses) == nil, "wss: watchdog resumed")
  A.assert_eq(fake.pending(), 1, "wss: fresh observation window after resume")

  -- 5) Now the stall fires normally (retry chain).
  fake.advance(TIMEOUT_MS)
  A.assert_eq(rec.count("watchdog.retry"), 1, "wss: retry after resume")
  local wr
  for _, item in ipairs(rec.items) do
    if item.event == "watchdog.retry" then
      wr = item
      break
    end
  end
  A.assert_eq(wr.payload.retry_count, 1, "wss: retry_count 1")
  A.assert_eq(wr.payload.reason, "no_message", "wss: no_message")
  A.assert_eq(rec.count("response.failed"), 1, "wss: one watchdog failure")
  local dec
  for _, item in ipairs(rec.items) do
    if item.event == "continuation.decided" then
      dec = item
    end
  end
  A.assert_eq(dec.payload.decision_kind, "retry", "wss: decision retry")
  A.assert_eq(fake.pending(), 1, "wss: backoff pending")

  -- 6) Backoff -> retry submit -> recovery.
  fake.advance(orch._watchdog:backoff_ms())
  A.assert_eq(calls(), 2, "wss: retry called the provider")
  A.assert_eq(#orch.session.requests, 2, "wss: two requests")
  A.assert_eq(orch.session.requests[2].intent, "retry", "wss: retry intent")
  A.assert_eq(orch.session.requests[2].retry_of, orch.session.requests[1].id, "wss: retry chained")
  A.assert_eq(orch.session.requests[2].terminal.state, "completed", "wss: retried request completed")
  A.assert_eq(orch.session.state, "waiting_for_user", "wss: session waiting_for_user")

  -- Soft-stop bookkeeping: requested twice (on/off); never completed (the
  -- toggle-off happened before any drain boundary consumed it).
  A.assert_eq(rec.count("chat.soft_stop_requested"), 2, "wss: soft_stop_requested on + off")
  A.assert_eq(rec.count("chat.soft_stop_completed"), 0, "wss: no soft_stop_completed (toggled off)")
  A.check(fake.idle(), "wss: timer removed at the end")
end

if A.ok then
  print("WATCHDOG_SOFTSTOP_SUPPRESSED_OK")
else
  error("WATCHDOG_SOFTSTOP_SUPPRESSED_FAILED count=" .. #A.failures)
end
