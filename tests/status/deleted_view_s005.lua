-- filepath: tests/status/deleted_view_s005.lua
--- S-005 deleted/invalid view safety (phase-5 W2):
---   * reconcile with an unknown/deleted view id: no throw, no state change
---   * reconcile repairs stale running sessions (view gone) and records the
---     diagnostic; a live busy view keeps its session running
---   * chat.closed for an unknown session: no throw, benign
---   * refresh observer failures are isolated (service keeps working, later
---     observers still run)

local assert_mod = require("tests.status.lib.assert")
local spine = require("maxa.runtime.status.spine")
local events = require("maxa.runtime.events")
local status_svc = require("maxa.runtime.status")

local ctx = assert_mod.new()
local check = ctx.check
local assert_eq = ctx.assert_eq

local bus = events.new()
local svc = status_svc.new({ events = bus, config = {} })
svc:start()

-- Reconcile with an unknown/deleted view id: no throw, no revision bump.
do
  local before = svc:snapshot()
  local ok, snap = pcall(function()
    return svc:reconcile({ { session_id = "dead-view", busy = false } })
  end)
  check(ok, "S005 reconcile unknown view does not throw")
  assert_eq(snap.revision, before.revision, "S005 reconcile unknown view: no revision bump")
  assert_eq(spine.counts_snapshot(snap).running_sessions, 0, "S005 reconcile unknown view: counts sane")
end

-- Stale running session repaired by reconcile (view disappeared).
do
  bus.emit("request.started", { session_id = "gone-session" })
  assert_eq(spine.counts_snapshot(svc:snapshot()).active_requests, 1, "S005 stale running present")
  local ok, snap = pcall(function()
    return svc:reconcile({})
  end)
  check(ok, "S005 reconcile repair does not throw")
  assert_eq(spine.counts_snapshot(snap).active_requests, 0, "S005 reconcile repairs stale running")
  assert_eq(spine.counts_snapshot(snap).running_sessions, 0, "S005 reconcile repairs running sessions")
  local log = svc:reconcile_log()
  check(#log >= 1 and log[#log].kind == "reconcile", "S005 reconcile recorded diagnostic")
end

-- Live busy view keeps its session running.
do
  bus.emit("request.started", { session_id = "live-session" })
  local ok, snap = pcall(function()
    return svc:reconcile({ { session_id = "live-session", busy = true } })
  end)
  check(ok, "S005 reconcile live view does not throw")
  assert_eq(spine.counts_snapshot(snap).active_requests, 1, "S005 reconcile keeps live busy session")
end

-- chat.closed for an unknown session: no throw, benign state change.
do
  local before = svc:snapshot()
  local ok = pcall(function()
    bus.emit("chat.closed", { session_id = "never-existed" })
  end)
  check(ok, "S005 chat.closed unknown session does not throw")
  local after = svc:snapshot()
  check(
    after == before or after.revision == before.revision + 1,
    "S005 chat.closed unknown session benign (revision " .. before.revision .. " -> " .. after.revision .. ")"
  )
end

-- Refresh observer failures are isolated.
do
  local calls = 0
  local off_bad = svc:on_refresh(function()
    error("observer boom")
  end)
  svc:on_refresh(function()
    calls = calls + 1
  end)
  local before = svc:snapshot()
  bus.emit("request.started", { session_id = "iso" })
  check(calls >= 1, "S005 refresh isolation: later observer still ran (got " .. calls .. ")")
  check(svc:snapshot().revision > before.revision, "S005 refresh isolation: snapshot advanced")
  off_bad()
end

-- Reconcile with malformed views entries: no throw.
do
  local ok = pcall(function()
    return svc:reconcile({ { session_id = 42 }, nil, "garbage" })
  end)
  check(ok, "S005 reconcile malformed views does not throw")
end

svc:dispose()
