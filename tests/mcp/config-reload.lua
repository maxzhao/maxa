-- filepath: tests/mcp/config-reload.lua
--- Phase-3 W3 fixture: `mcp/config-reload` (runtime-fixture-contract).
---   * unchanged servers are preserved (same generation, no respawn),
---   * changed servers restart under one operation owner (new generation,
---     capabilities re-published),
---   * removed servers stop and drop out of the registry,
---   * added enabled servers start,
---   * the aggregate `mcp.server_state` update emits exactly once per reload,
---     after the transitions ran, with the full per-server snapshot,
---   * reserved ids are DYNAMIC: an id registered natively cannot be shadowed
---     by a project declaration (typed error recorded, remaining servers still load).

local assert_mod = require("tests.state.lib.assert")
local harness = require("tests.mcp.lib.harness")

local A = assert_mod.new()
local h = harness.new()
local rec = harness.recorder(h)
local reg = h.registry()

---@param id string
---@param command string
---@return table cfg record
local function server_cfg(id, command)
  return h.cfg(id, { command = command })
end

local cfg1 = {
  version = 1,
  project_root = "/tmp/proj",
  servers = {
    A = server_cfg("A", "bin-a"),
    B = server_cfg("B", "bin-b"),
    C = server_cfg("C", "bin-c"),
  },
  unavailable = {},
  warnings = {},
}

local res1 = reg:apply_config(cfg1)
A.assert_eq(#res1.added, 3, "cr: three servers added on first load")
A.assert_eq(#res1.changed, 0, "cr: no changed on first load")
A.assert_eq(#res1.removed, 0, "cr: no removed on first load")
A.assert_eq(reg:get("A").server.state, "connected", "cr: A connected")
A.assert_eq(reg:get("A").server.generation, 1, "cr: A generation 1")
A.assert_eq(h.spawned_by_id["A"], 1, "cr: A spawned once")
A.assert_eq(h.tool_reg:count(), 6, "cr: three servers x two tools registered")

-- One aggregate event already fired for the first load.
local first_agg = 0
for _, item in ipairs(rec.items) do
  if item.event == "mcp.server_state" and item.payload.aggregate then
    first_agg = first_agg + 1
  end
end
A.assert_eq(first_agg, 1, "cr: one aggregate event after first load")

local cfg2 = {
  version = 1,
  project_root = "/tmp/proj",
  servers = {
    A = server_cfg("A", "bin-a"), -- unchanged
    B = server_cfg("B", "bin-b-new"), -- changed (command)
    D = server_cfg("D", "bin-d"), -- added
  },
  unavailable = {},
  warnings = {},
}

local res2 = reg:apply_config(cfg2)
A.assert_eq(#res2.unchanged, 1, "cr: A unchanged")
A.assert_eq(#res2.changed, 1, "cr: B changed")
A.assert_eq(#res2.removed, 1, "cr: C removed")
A.assert_eq(#res2.added, 1, "cr: D added")

-- Unchanged server: same instance, same generation, never respawned.
A.assert_eq(reg:get("A").server.generation, 1, "cr: unchanged keeps generation")
A.assert_eq(h.spawned_by_id["A"], 1, "cr: unchanged never respawned")
A.assert_eq(reg:get("A").server.state, "connected", "cr: unchanged stays connected")

-- Changed server: restarted with a new generation and re-published tools.
A.assert_eq(reg:get("B").server.generation, 2, "cr: changed restarted (new generation)")
A.assert_eq(h.spawned_by_id["B"], 2, "cr: changed respawned once")
A.assert_eq(reg:get("B").server.state, "connected", "cr: changed connected again")

-- Removed server: stopped and dropped.
A.check(reg:get("C") == nil, "cr: removed server dropped from registry")

-- Added server: started.
A.assert_eq(reg:get("D").server.generation, 1, "cr: added server generation 1")
A.assert_eq(reg:get("D").server.state, "connected", "cr: added server connected")

-- Tool registry reflects the new world (A 2 + B 2 + D 2 = 6).
A.assert_eq(h.tool_reg:count(), 6, "cr: tool registry after reload")

-- Aggregate event: exactly once per reload, with the full snapshot.
local agg = 0
local agg_payload
for _, item in ipairs(rec.items) do
  if item.event == "mcp.server_state" and item.payload.aggregate then
    agg = agg + 1
    agg_payload = item.payload
  end
end
A.assert_eq(agg, 2, "cr: aggregate event exactly once per reload (2 total)")
if agg_payload then
  A.assert_eq(agg_payload.reason, "config_reload", "cr: aggregate reason")
  local servers = agg_payload.servers
  A.check(
    servers.A ~= nil and servers.A.generation == 1 and servers.A.state == "connected",
    "cr: aggregate has A gen 1"
  )
  A.check(
    servers.B ~= nil and servers.B.generation == 2 and servers.B.state == "connected",
    "cr: aggregate has B gen 2"
  )
  A.check(servers.D ~= nil and servers.D.state == "connected", "cr: aggregate has D")
  A.check(servers.C == nil, "cr: removed server absent from aggregate")
end

-- Reserved native ids are DYNAMIC: an id registered natively cannot be
-- shadowed by a project declaration; unregistered business names are not
-- pre-reserved (no business inventory in the generic runtime).
do
  local native_mod = require("maxa.runtime.mcp.native")
  local ns = native_mod.native_server({
    definition = { id = "test-native", name = "test-native", tools = {} },
    events = h.bus,
    clock = h.clock,
    tool_registry = h.tool_reg,
  })
  local nentry, nerr = reg:register_native(ns)
  A.check(nentry ~= nil and nerr == nil, "cr: test-native registered natively")
  A.check(reg:is_reserved("test-native") == true, "cr: registered id is reserved (dynamic)")

  local res3 = reg:apply_config({
    version = 1,
    project_root = "/tmp/proj",
    servers = {
      ["test-native"] = server_cfg("test-native", "shadow-bin"),
      keep = server_cfg("keep", "bin-keep"),
    },
    unavailable = {},
    warnings = {},
  })
  A.check(res3.errors["test-native"] ~= nil, "cr: reserved id rejected with typed error")
  if res3.errors["test-native"] then
    A.assert_eq(res3.errors["test-native"].code, "invalid_argument", "cr: reserved rejection code")
    A.check(
      res3.errors["test-native"].cause ~= nil and res3.errors["test-native"].cause.reason == "reserved_native_id",
      "cr: reserved rejection reason"
    )
  end
  A.check(reg:get("test-native") ~= nil and reg:get("test-native").kind == "native", "cr: native entry survives (not replaced by project)")
  A.check(reg:get("keep") ~= nil, "cr: non-reserved server still loads")
  A.check(reg:is_reserved("mcpx") == false, "cr: unregistered business name is NOT pre-reserved")
  A.check(reg:is_reserved("genai") == false, "cr: no business inventory is baked in")
  A.check(reg:is_reserved("misc") == false, "cr: misc is not reserved (bucket removed)")
end

if A.ok then
  print("MCP_CONFIG_RELOAD_OK")
else
  error("MCP_CONFIG_RELOAD_FAILED count=" .. #A.failures)
end
