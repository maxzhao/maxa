-- filepath: tests/status/billing_s004.lua
--- S-004 billing/quota projection (phase-5 W2):
---   * nil provider -> disabled typed result
---   * working function provider -> available result with data
---   * throwing provider -> stale typed result, never a raise
---   * unresolvable / non-callable module provider -> stale typed result
---   * service layer: disabled by default config; enabled+throwing provider
---     yields a typed stale projection without raising

local assert_mod = require("tests.status.lib.assert")
local billing = require("maxa.runtime.status.billing")
local events = require("maxa.runtime.events")
local status_svc = require("maxa.runtime.status")

local ctx = assert_mod.new()
local check = ctx.check
local assert_eq = ctx.assert_eq

-- Disabled: nil provider.
do
  local r = billing.snapshot(nil, nil)
  assert_eq(r.available, false, "S004 nil provider unavailable")
  assert_eq(r.enabled, false, "S004 nil provider disabled")
end

-- Working function provider receives usage and returns data.
do
  local r = billing.snapshot(function(usage)
    return { remaining = 100, limit = 1000, used = usage and usage.input_tokens or 0 }
  end, { input_tokens = 42 })
  assert_eq(r.available, true, "S004 fn provider available")
  assert_eq(r.enabled, true, "S004 fn provider enabled")
  assert_eq(r.data.remaining, 100, "S004 fn provider data")
  assert_eq(r.data.used, 42, "S004 fn provider receives usage")
end

-- Throwing provider: typed stale result, no raise.
do
  local ok, r = pcall(billing.snapshot, function()
    error("quota service down")
  end, {})
  check(ok, "S004 throwing provider does not raise")
  assert_eq(r.available, false, "S004 throwing provider unavailable")
  assert_eq(r.stale, true, "S004 throwing provider stale")
  check(type(r.error) == "string", "S004 throwing provider error string")
end

-- Unresolvable module name: stale typed result.
do
  local ok, r = pcall(billing.snapshot, "maxa.runtime.status.no_such_module_xyz", {})
  check(ok, "S004 missing module does not raise")
  assert_eq(r.available, false, "S004 missing module unavailable")
  assert_eq(r.stale, true, "S004 missing module stale")
end

-- Non-callable module (a table without .snapshot): stale typed result.
do
  local ok, r = pcall(billing.snapshot, "maxa.runtime.status", {})
  check(ok, "S004 non-callable module does not raise")
  assert_eq(r.available, false, "S004 non-callable module unavailable")
  assert_eq(r.stale, true, "S004 non-callable module stale")
end

-- Module provider exposing .snapshot(usage) works by name (injected fake
-- provider module; the module contract matches the function contract).
do
  package.loaded["tests.status.fake_billing_provider"] = {
    snapshot = function(usage)
      return { quota = 123, used = usage and usage.input_tokens or 0 }
    end,
  }
  local ok, r = pcall(billing.snapshot, "tests.status.fake_billing_provider", { input_tokens = 5 })
  check(ok, "S004 callable module does not raise")
  assert_eq(r.available, true, "S004 callable module available")
  assert_eq(r.data.quota, 123, "S004 callable module data")
  assert_eq(r.data.used, 5, "S004 callable module receives usage")
end

-- Service layer: disabled by default config (status.billing absent).
do
  local bus = events.new()
  local svc = status_svc.new({ events = bus, config = {} })
  svc:start()
  local r = svc:billing_snapshot()
  assert_eq(r.enabled, false, "S004 service disabled default")
  assert_eq(r.available, false, "S004 service unavailable default")
  svc:dispose()
end

-- Service layer: enabled with a throwing provider -> typed stale, never raises.
do
  local bus = events.new()
  local svc = status_svc.new({
    events = bus,
    config = { status = { billing = { enabled = true, provider = function()
      error("quota backend unreachable")
    end } } },
  })
  svc:start()
  local ok, r = pcall(function()
    return svc:billing_snapshot()
  end)
  check(ok, "S004 service billing never raises")
  check(r ~= nil and r.available == false and r.stale == true, "S004 service billing typed stale")
  svc:dispose()
end

-- Service layer: enabled provider returns data through the typed contract.
do
  local bus = events.new()
  local svc = status_svc.new({
    events = bus,
    config = { status = { billing = { enabled = true, provider = function(usage)
      return { quota = 9000, used = usage and usage.input_tokens or 0 }
    end } } },
  })
  svc:start()
  local ok, r = pcall(function()
    return svc:billing_snapshot()
  end)
  check(ok, "S004 service enabled provider no raise")
  check(r ~= nil and r.available == true and r.data ~= nil and r.data.quota == 9000, "S004 service enabled provider data")
  svc:dispose()
end
