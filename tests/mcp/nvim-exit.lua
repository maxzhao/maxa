-- filepath: tests/mcp/nvim-exit.lua
--- Phase-3 W4 fixture: `mcp/nvim-exit` (runtime-fixture-contract).
---   * external process handles and native lifecycle hooks close on shutdown,
---   * all capabilities are removed (tool registry empty, diagnostics too),
---   * repeated shutdown is idempotent (no errors, no new work),
---   * the shutdown path has NO UI dependency: this fixture runs headless and
---     never touches buffers/windows/autocmds — any UI coupling would throw.
---
--- Fixture convention: prints MCP_NVIM_EXIT_OK on success; throws on failure.
local assert_mod = require("tests.state.lib.assert")
local harness = require("tests.mcp.lib.harness")
local mcp_config = require("maxa.runtime.mcp.config")
local native_mod = require("maxa.runtime.mcp.native")

local A = assert_mod.new()
local h = harness.new()
local reg = h.registry()
local manager = native_mod.new({ registry = reg })

-- External server through the full config path (registry-owned, fake process).
local root = h.write_project(
  [[
schema_version: 1
servers:
  demo:
    command: node
    args: [fake.js]
]],
  "nvim-exit"
)
local cfg = mcp_config.load(root)
local app = reg:apply_config(cfg)
A.check(app ~= nil and (not app.errors or vim.tbl_isempty(app.errors)), "ne: config applied without errors")
local ext_entry = reg:get("demo")
A.check(ext_entry ~= nil and ext_entry.kind == "external", "ne: external server registered")
A.check(ext_entry and ext_entry.server and ext_entry.server.state == "connected", "ne: external connected")
local proc = h.spawned[1]
A.check(proc ~= nil and proc.started == true, "ne: external process spawned")

-- Native servers + diagnostics enabled alongside the external server.
-- Test-owned primitive ids (generic mechanism; no business names).
local native_ids = { "test-native-1", "test-native-2" }
for _, id in ipairs(native_ids) do
  local server, serr = manager:register({
    id = id,
    name = id,
    tools = {
      {
        id = id .. "/ping",
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
  })
  A.check(server ~= nil and serr == nil, "ne: native " .. id .. " registered")
end
manager:register_diagnostics()
for _, id in ipairs(native_ids) do
  local res, err = manager:enable(id)
  A.check(err == nil and res ~= nil and res.state == "connected", "ne: native " .. id .. " enabled")
end
local total_tools = 2 + 2 + 1 -- external alpha/beta + 2 native ping tools + diagnostics/echo
A.assert_eq(h.tool_reg:count(), total_tools, "ne: all capabilities exposed before shutdown")

-- Shutdown: external processes + native lifecycle hooks close, no UI.
reg:stop_all()
manager:teardown()

A.assert_eq(ext_entry.server.state, "stopped", "ne: external stopped")
A.check(proc.closed == true, "ne: external process handle closed")
A.check(ext_entry.server.client == nil, "ne: external client reaped")
for _, id in ipairs(native_ids) do
  local entry = reg:get(id)
  A.check(entry ~= nil and entry.server.state == "stopped", "ne: native " .. id .. " stopped")
end
A.assert_eq(h.tool_reg:count(), 0, "ne: all capabilities removed")
A.check(h.tool_reg:resolve("diagnostics/echo") == nil, "ne: diagnostic tool unregistered")

-- Idempotent double-cleanup (repeat shutdown is a no-op, no errors).
local ok1 = pcall(function()
  reg:stop_all()
  manager:teardown()
end)
A.check(ok1, "ne: repeated shutdown is a no-op")
A.assert_eq(h.tool_reg:count(), 0, "ne: tool registry still empty after repeat")

-- A bare manager teardown (nothing registered) is also safe.
local h2 = harness.new()
local reg2 = h2.registry()
local m2 = native_mod.new({ registry = reg2 })
local ok2 = pcall(function()
  m2:teardown()
end)
A.check(ok2, "ne: teardown with nothing registered is safe")

h.cleanup(root)

if A.ok then
  print("MCP_NVIM_EXIT_OK")
else
  error("MCP_NVIM_EXIT_FAILED count=" .. #A.failures)
end
