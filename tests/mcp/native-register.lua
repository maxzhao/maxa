-- filepath: tests/mcp/native-register.lua
--- Phase-3 W4 fixture: `mcp/native-register` (runtime-fixture-contract).
---   * native primitives register from generic caller-supplied definitions with
---     validated tool schemas (NO business primitive names are baked into the
---     runtime; this fixture uses test-owned primitive ids),
---   * capability exposure happens only after enable (connected gate;
---     capability revision bumps exactly once per publish),
---   * registered tool handlers are callable and return standard results,
---   * the explicit diagnostic primitive (diagnostics/echo) is exposed with a
---     validated schema and returns a standard success result.
---
--- Fixture convention: prints MCP_NATIVE_REGISTER_OK on success; throws on failure.
local assert_mod = require("tests.state.lib.assert")
local harness = require("tests.mcp.lib.harness")
local native_mod = require("maxa.runtime.mcp.native")

local A = assert_mod.new()
local h = harness.new()
local reg = h.registry()
local manager = native_mod.new({ registry = reg })

--- Test-owned primitive definition (generic shape; no business names).
local function ping_tool()
  return {
    id = "test-native/ping",
    name = "ping",
    description = "Test primitive tool: returns pong.",
    input_schema = { type = "object", properties = {}, additionalProperties = false },
    execution = { mode = "sync", timeout_ms = nil, cancellable = false, side_effect = "none" },
    result = { durable = true, display = "summary" },
    run = function()
      return "pong"
    end,
  }
end

--------------------------------------------------------------------------------
-- A. Invalid definitions fail closed (registration-level validation)
--------------------------------------------------------------------------------
do
  local bad1, berr1 = manager:register({ name = "no-id" })
  A.check(bad1 == nil and berr1 ~= nil, "nr: definition without id rejected")
  if berr1 then
    A.assert_eq(berr1.code, "invalid_argument", "nr: invalid definition uses INVALID_ARGUMENT")
    A.check(berr1.cause and berr1.cause.reason == "invalid_id", "nr: invalid id cause reason")
  end
  local bad2, berr2 = manager:register({ id = "bad!id", tools = {} })
  A.check(bad2 == nil and berr2 ~= nil, "nr: malformed id rejected")
  local bad3, berr3 = manager:register({ id = "bad-tools", tools = "not-a-list" })
  A.check(bad3 == nil and berr3 ~= nil, "nr: non-list tools rejected")
  if berr3 then
    A.check(berr3.cause and berr3.cause.reason == "invalid_tools", "nr: invalid tools cause reason")
  end
end

--------------------------------------------------------------------------------
-- B. Generic primitive registers as a native server (no misc, no business ids)
--------------------------------------------------------------------------------
do
  local server, serr = manager:register({ id = "test-native", name = "test-native", tools = { ping_tool() } })
  A.check(server ~= nil and serr == nil, "nr: test-native registered")
  A.assert_eq(#reg:list(), 1, "nr: exactly one native server registered")
  A.check(reg:get("misc") == nil, "nr: misc bucket is NOT registered")
  A.check(reg:get("mcpx") == nil, "nr: no business primitive names are baked in")
  local entry = reg:get("test-native")
  A.check(entry ~= nil and entry.kind == "native", "nr: test-native registered as native")
  A.check(entry.server ~= nil, "nr: server instance bound")
  A.assert_eq(entry.server.state, "stopped", "nr: registered stopped")
  A.assert_eq(entry.server.capabilities_revision, 0, "nr: no capabilities before enable")
  -- Registration reserves the id against project shadowing (dynamic).
  A.check(reg:is_reserved("test-native") == true, "nr: registered id is reserved")
end

--------------------------------------------------------------------------------
-- C. Tool schema validation at registration (native tools + diagnostics)
--------------------------------------------------------------------------------
do
  local dout = manager:register_diagnostics()
  A.check(dout.tools["diagnostics/echo"] ~= nil, "nr: diagnostics.echo registered")
  A.check(dout.errors["diagnostics/echo"] == nil, "nr: diagnostics.echo schema valid")
  local echo = h.tool_reg:resolve("diagnostics/echo")
  A.check(echo ~= nil, "nr: diagnostics.echo resolvable by id")
  if echo then
    A.assert_eq(echo.input_schema.type, "object", "nr: echo schema object")
    A.check(
      type(echo.input_schema.properties) == "table"
        and echo.input_schema.properties.message
        and echo.input_schema.properties.message.type == "string",
      "nr: echo schema message property"
    )
    A.check(
      echo.input_schema.required ~= nil and vim.tbl_contains(echo.input_schema.required, "message"),
      "nr: echo schema requires message"
    )
    A.assert_eq(echo.execution.mode, "sync", "nr: echo executes synchronously")
  end
end

--------------------------------------------------------------------------------
-- D. Capability exposure only after enable (connected gate + revision)
--------------------------------------------------------------------------------
do
  local svr = reg:get("test-native").server
  A.assert_eq(h.tool_reg:count(), 1, "nr: only diagnostics.echo registered before enable")
  local en, enerr = manager:enable("test-native")
  A.check(enerr == nil, "nr: enable accepted")
  A.check(en ~= nil and en.state == "connected", "nr: test-native connected after enable")
  A.assert_eq(svr.state, "connected", "nr: server state connected")
  A.assert_eq(svr.capabilities_revision, 1, "nr: capability revision bumped once")
  A.check(svr.capabilities.tools ~= nil and #svr.capabilities.tools == 1, "nr: one capability tool published")
  local ping = h.tool_reg:resolve("test-native/ping")
  A.check(ping ~= nil, "nr: test-native/ping exposed after enable")
  -- Registry snapshot projects native entries with their state.
  local snap = reg:snapshot()
  A.check(snap["test-native"] ~= nil and snap["test-native"].kind == "native" and snap["test-native"].state == "connected", "nr: snapshot projects native entry")
end

--------------------------------------------------------------------------------
-- E. Registered tool handler: callable and returns a standard result
--------------------------------------------------------------------------------
do
  local ping = h.tool_reg:resolve("test-native/ping")
  A.check(ping ~= nil and type(ping.run) == "function", "nr: ping handler bound")
  if ping and type(ping.run) == "function" then
    A.assert_eq(ping.run({}), "pong", "nr: ping returns standard success result")
  end
end

--------------------------------------------------------------------------------
-- F. Diagnostic echo: standard result + defensive clamp
--------------------------------------------------------------------------------
do
  local echo = h.tool_reg:resolve("diagnostics/echo")
  A.check(echo ~= nil and type(echo.run) == "function", "nr: echo handler bound")
  if echo and type(echo.run) == "function" then
    A.assert_eq(echo.run({ message = "hi", repeat_count = 3 }), "hihihi", "nr: echo standard success result")
    A.assert_eq(echo.run({ message = "x", repeat_count = 0 }), "x", "nr: echo clamps repeat_count to >= 1")
    A.assert_eq(echo.run({ message = "y", repeat_count = 500 }), string.rep("y", 100), "nr: echo clamps repeat_count to <= 100")
  end
end

if A.ok then
  print("MCP_NATIVE_REGISTER_OK")
else
  error("MCP_NATIVE_REGISTER_FAILED count=" .. #A.failures)
end
