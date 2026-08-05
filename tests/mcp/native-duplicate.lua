-- filepath: tests/mcp/native-duplicate.lua
--- Phase-3 W4 fixture: `mcp/native-duplicate` (runtime-fixture-contract).
---   * duplicate native registration deterministically returns the existing
---     server while recording a typed error,
---   * no duplicate capability entries (tool registry count and capability
---     revision stay stable),
---   * registry-level register_native duplicates fail closed; ANY id may be
---     registered natively and becomes reserved on registration (dynamic
---     reservation, no business-name inventory).
---
--- Fixture convention: prints MCP_NATIVE_DUPLICATE_OK on success; throws on failure.
local assert_mod = require("tests.state.lib.assert")
local harness = require("tests.mcp.lib.harness")
local native_mod = require("maxa.runtime.mcp.native")

local A = assert_mod.new()
local h = harness.new()
local reg = h.registry()
local manager = native_mod.new({ registry = reg })

local DEF = {
  id = "dup-native",
  name = "dup-native",
  tools = {
    {
      id = "dup-native/ping",
      name = "ping",
      description = "Test tool.",
      input_schema = { type = "object", properties = {}, additionalProperties = false },
      execution = { mode = "sync", timeout_ms = nil, cancellable = false, side_effect = "none" },
      result = { durable = true, display = "summary" },
      run = function()
        return "pong"
      end,
    },
  },
}

--------------------------------------------------------------------------------
-- A. Manager-level duplicate: existing server + recorded typed error
--------------------------------------------------------------------------------
do
  local s1, e1 = manager:register(DEF)
  A.check(s1 ~= nil and e1 == nil, "nd: first registration succeeded")
  local s2, e2 = manager:register(DEF)
  A.check(s2 == s1 and s2 ~= nil, "nd: duplicate returns the existing server")
  A.check(e2 ~= nil, "nd: duplicate records an error")
  if e2 then
    A.assert_eq(e2.code, "invalid_argument", "nd: duplicate error code")
    A.check(e2.cause and e2.cause.reason == "duplicate_native_registration", "nd: duplicate cause reason")
    A.check(e2.message:find("dup-native", 1, true) ~= nil, "nd: duplicate message names the id")
  end
  -- Deterministic: a third registration behaves identically.
  local s3, e3 = manager:register(DEF)
  A.check(s3 == s1, "nd: third registration returns the same server")
  A.check(e3 ~= nil and e3.code == e2.code and e3.cause and e3.cause.reason == e2.cause.reason, "nd: third registration records the same error")
end

--------------------------------------------------------------------------------
-- B. No duplicate capability entries
--------------------------------------------------------------------------------
do
  local en, enerr = manager:enable("dup-native")
  A.check(enerr == nil and en ~= nil and en.state == "connected", "nd: dup-native enabled")
  local server = reg:get("dup-native").server
  A.assert_eq(h.tool_reg:count(), 1, "nd: exactly one capability entry after enable")
  A.assert_eq(server.capabilities_revision, 1, "nd: capability revision 1")
  -- Duplicate registration after enable must not republish.
  local s4, e4 = manager:register(DEF)
  A.check(s4 == server, "nd: post-enable duplicate returns the same server")
  A.check(e4 ~= nil, "nd: post-enable duplicate records error")
  A.assert_eq(h.tool_reg:count(), 1, "nd: duplicate registration adds no capability entry")
  A.assert_eq(server.capabilities_revision, 1, "nd: duplicate registration does not bump revision")
end

--------------------------------------------------------------------------------
-- C. Registry-level register_native: duplicates fail closed
--------------------------------------------------------------------------------
do
  local alt = native_mod.native_server({
    definition = DEF,
    events = h.bus,
    clock = h.clock,
    tool_registry = h.tool_reg,
  })
  local entry, rerr = reg:register_native(alt)
  A.check(entry ~= nil and entry.server ~= alt, "nd: registry duplicate returns the existing entry")
  A.check(rerr ~= nil and rerr.cause and rerr.cause.reason == "duplicate_native_registration", "nd: registry duplicate error reason")
end

--------------------------------------------------------------------------------
-- D. Generic registration: any id registers and becomes reserved dynamically
--------------------------------------------------------------------------------
do
  local fresh = native_mod.native_server({
    definition = { id = "fresh-native", name = "fresh-native", tools = {} },
    events = h.bus,
    clock = h.clock,
    tool_registry = h.tool_reg,
  })
  local fentry, ferr = reg:register_native(fresh)
  A.check(fentry ~= nil and ferr == nil, "nd: any id may register natively (generic mechanism)")
  A.check(reg:get("fresh-native") ~= nil, "nd: fresh-native entry exists")
  A.check(reg:is_reserved("fresh-native") == true, "nd: registration reserves the id dynamically")
  A.check(reg:is_reserved("mcpx") == false, "nd: no business primitive names are pre-reserved")
  A.check(reg:is_reserved("misc") == false, "nd: misc is not reserved (bucket removed, not baked in)")
  -- The last-error projection carries the recorded duplicate errors.
  local le = reg:last_errors()
  A.check(le["dup-native"] ~= nil, "nd: recorded duplicate error visible via last_errors")
end

if A.ok then
  print("MCP_NATIVE_DUPLICATE_OK")
else
  error("MCP_NATIVE_DUPLICATE_FAILED count=" .. #A.failures)
end
