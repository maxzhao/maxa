-- filepath: tests/mcp/native-enable-disable.lua
--- Phase-3 W4 fixture: `mcp/native-enable-disable` (runtime-fixture-contract).
---   * enable/disable switch a native server between stopped and connected,
---   * capabilities are published on enable and removed on disable,
---   * per-server `mcp.server_state` transitions are emitted exactly once with
---     the full payload (kind native, generation 0),
---   * each enable()/disable() that performs a transition emits exactly ONE
---     aggregate `mcp.server_state`; idempotent no-ops emit nothing.
---   Uses test-owned primitive ids (no business names in the runtime).
---
--- Fixture convention: prints MCP_NATIVE_ENABLE_DISABLE_OK on success; throws on failure.
local assert_mod = require("tests.state.lib.assert")
local harness = require("tests.mcp.lib.harness")
local native_mod = require("maxa.runtime.mcp.native")

local A = assert_mod.new()
local h = harness.new()
local rec = harness.recorder(h)
local reg = h.registry()
local manager = native_mod.new({ registry = reg })

local function tool_def(id)
  return {
    id = id .. "/ping",
    name = "ping",
    description = "Test tool.",
    input_schema = { type = "object", properties = {}, additionalProperties = false },
    execution = { mode = "sync", timeout_ms = nil, cancellable = false, side_effect = "none" },
    result = { durable = true, display = "summary" },
    run = function()
      return "pong"
    end,
  }
end

-- Register test primitives: one primary + a set for the multi-enable section.
manager:register({ id = "test-native", name = "test-native", tools = { tool_def("test-native") } })
for _, id in ipairs({ "test-a", "test-b", "test-c" }) do
  manager:register({ id = id, name = id, tools = { tool_def(id) } })
end

local function aggregate_payloads()
  local out = {}
  for _, item in ipairs(rec.items) do
    if item.event == "mcp.server_state" and item.payload.aggregate then
      out[#out + 1] = item.payload
    end
  end
  return out
end

local function server_events(id)
  local out = {}
  for _, item in ipairs(rec.items) do
    if item.event == "mcp.server_state" and not item.payload.aggregate and item.payload.server_id == id then
      out[#out + 1] = item.payload
    end
  end
  return out
end

--------------------------------------------------------------------------------
-- A. enable: stopped -> connected, capabilities published, events exactly once
--------------------------------------------------------------------------------
do
  local svr = reg:get("test-native").server
  A.assert_eq(svr.state, "stopped", "ee: registered stopped")
  local en, enerr = manager:enable("test-native")
  A.check(enerr == nil, "ee: enable accepted")
  A.check(en ~= nil and en.state == "connected" and en.already == nil, "ee: enable result connected")
  A.assert_eq(svr.state, "connected", "ee: server connected")
  A.assert_eq(svr.capabilities_revision, 1, "ee: capabilities published once")
  A.assert_eq(h.tool_reg:count(), 1, "ee: one tool exposed")
  A.check(h.tool_reg:resolve("test-native/ping") ~= nil, "ee: test-native/ping exposed")

  local evs = server_events("test-native")
  A.assert_eq(#evs, 1, "ee: one per-server transition")
  if evs[1] then
    A.assert_eq(evs[1].state, "connected", "ee: transition state")
    A.assert_eq(evs[1].reason, "start", "ee: transition reason")
    A.assert_eq(evs[1].revision, 1, "ee: revision 1")
    A.assert_eq(evs[1].kind, "native", "ee: kind native")
    A.assert_eq(evs[1].generation, 0, "ee: no process, generation 0")
    A.assert_eq(evs[1].capabilities_revision, 1, "ee: event carries capability revision")
    A.assert_eq(evs[1].server_id, "test-native", "ee: event server_id")
  end
  local aggs = aggregate_payloads()
  A.assert_eq(#aggs, 1, "ee: aggregate emitted exactly once")
  A.assert_eq(aggs[1].reason, "native_enable", "ee: aggregate reason")
  A.check(aggs[1].servers["test-native"] ~= nil and aggs[1].servers["test-native"].state == "connected", "ee: aggregate snapshot shows connected")
  A.check(aggs[1].servers["test-native"].kind == "native", "ee: aggregate snapshot kind native")
  A.check(aggs[1].servers["test-a"] ~= nil and aggs[1].servers["test-a"].state == "stopped", "ee: aggregate snapshot shows others stopped")
end

--------------------------------------------------------------------------------
-- B. idempotent enable: no events, no duplicate publish
--------------------------------------------------------------------------------
do
  local svr = reg:get("test-native").server
  local before = #rec.items
  local en2, en2err = manager:enable("test-native")
  A.check(en2err == nil and en2 ~= nil and en2.already == true, "ee: idempotent enable reports already")
  A.assert_eq(#rec.items, before, "ee: idempotent enable emits nothing")
  A.assert_eq(svr.capabilities_revision, 1, "ee: no duplicate publish")
  A.assert_eq(h.tool_reg:count(), 1, "ee: no duplicate capability entry")
end

--------------------------------------------------------------------------------
-- C. disable: connected -> stopped, capabilities removed, aggregate once
--------------------------------------------------------------------------------
do
  local svr = reg:get("test-native").server
  local dis, diserr = manager:disable("test-native")
  A.check(diserr == nil, "ee: disable accepted")
  A.check(dis ~= nil and dis.state == "stopped", "ee: disable result stopped")
  A.assert_eq(svr.state, "stopped", "ee: server stopped")
  A.assert_eq(h.tool_reg:count(), 0, "ee: capabilities removed")
  A.check(h.tool_reg:resolve("test-native/ping") == nil, "ee: tool unregistered")

  local evs = server_events("test-native")
  A.assert_eq(#evs, 2, "ee: two per-server transitions total")
  A.assert_eq(evs[2].state, "stopped", "ee: stop transition state")
  A.assert_eq(evs[2].reason, "stop", "ee: stop transition reason")
  A.assert_eq(evs[2].revision, 2, "ee: stop revision 2")
  local aggs = aggregate_payloads()
  A.assert_eq(#aggs, 2, "ee: second aggregate exactly once")
  A.assert_eq(aggs[2].reason, "native_disable", "ee: disable aggregate reason")
  A.check(aggs[2].servers["test-native"].state == "stopped", "ee: disable aggregate snapshot stopped")

  local dis2, dis2err = manager:disable("test-native")
  A.check(dis2err == nil and dis2 ~= nil and dis2.already == true, "ee: idempotent disable reports already")
  A.assert_eq(#aggregate_payloads(), 2, "ee: idempotent disable adds no aggregate")
end

--------------------------------------------------------------------------------
-- D. full enable/disable cycle repeats deterministically
--------------------------------------------------------------------------------
do
  local svr = reg:get("test-native").server
  manager:enable("test-native")
  A.assert_eq(svr.capabilities_revision, 2, "ee: re-enable re-publishes (revision 2)")
  A.assert_eq(h.tool_reg:count(), 1, "ee: tools re-registered")
  manager:disable("test-native")
  A.assert_eq(svr.state, "stopped", "ee: cycle returns to stopped")
  A.assert_eq(h.tool_reg:count(), 0, "ee: cycle removes capabilities")
  local evs = server_events("test-native")
  A.assert_eq(#evs, 4, "ee: cycle emits exactly 4 transitions")
  A.assert_eq(#aggregate_payloads(), 4, "ee: cycle emits 4 aggregates (one per transition)")
end

--------------------------------------------------------------------------------
-- E. unknown ids fail closed
--------------------------------------------------------------------------------
do
  local ures, uerr = manager:enable("nope")
  A.check(ures == nil and uerr ~= nil, "ee: unknown enable rejected")
  if uerr then
    A.assert_eq(uerr.code, "invalid_argument", "ee: unknown id typed error")
    A.check(uerr.cause and uerr.cause.reason == "unknown_native_server", "ee: unknown id cause")
  end
  local dres, derr = manager:disable("nope")
  A.check(dres == nil and derr ~= nil, "ee: unknown disable rejected")
end

--------------------------------------------------------------------------------
-- F. many natives: one aggregate per transition batch
--------------------------------------------------------------------------------
do
  local before = #aggregate_payloads()
  for _, id in ipairs({ "test-a", "test-b", "test-c" }) do
    local res, err = manager:enable(id)
    A.check(err == nil and res ~= nil and res.state == "connected", "ee: " .. id .. " enabled")
  end
  local aggs = aggregate_payloads()
  A.assert_eq(#aggs, before + 3, "ee: one aggregate per native enable")
  A.assert_eq(h.tool_reg:count(), 3, "ee: three more tools exposed")
end

if A.ok then
  print("MCP_NATIVE_ENABLE_DISABLE_OK")
else
  error("MCP_NATIVE_ENABLE_DISABLE_FAILED count=" .. #A.failures)
end
