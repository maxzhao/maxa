-- filepath: tests/tools/async-continuation.lua
--- Phase-3 regression (user-reported UI bug): a REAL external MCP tool
--- (async mode) completing its round must leave the session ready for the
--- next manual submit. Root cause was mcp client callbacks dispatched inside
--- the libuv fast-event context, where the automatic continuation submit hit
--- `vim.fn.tempname` (E5560) and the session stayed busy.
---
--- Asserts: async submit -> model-injected tool call -> real node fixture
--- process executes -> barrier once -> continuation once -> session
--- waiting_for_user -> SECOND manual submit succeeds.
---
--- Fixture convention: prints TOOLS_ASYNC_CONTINUATION_OK on success; throws on failure.
local assert_mod = require("tests.state.lib.assert")
local events = require("maxa.runtime.events")
local tools_registry = require("maxa.runtime.tools.registry")
local mcp_config = require("maxa.runtime.mcp.config")
local mcp_registry = require("maxa.runtime.mcp.registry")
local host = require("maxa.runtime.host.nvim")
local normalize = require("maxa.runtime.protocol.normalize")

local A = assert_mod.new()
local root = "/home/maxzhao/maxa"

local tmp = vim.fn.tempname() .. "-p3ac"
vim.fn.mkdir(tmp .. "/.maxa/mcp", "p")
local fixture = root .. "/tests/mcp/fixtures/stdio_server.mjs"
local yaml = ("schema_version: 1\nservers:\n  fixture-echo:\n    enabled: true\n    transport: stdio\n    command: node\n    args: [%q]\n    cwd: %q\n    request_timeout_ms: 10000\n    startup_timeout_ms: 10000\n"):format(fixture, root)
local fh = assert(io.open(tmp .. "/.maxa/mcp/servers.yaml", "wb"))
fh:write(yaml)
fh:close()

local bus = events.new()
local tool_reg = tools_registry.new()
local cfg = assert(mcp_config.load(tmp))
local reg = mcp_registry.new({ events = bus, tool_registry = tool_reg })
local apply = reg:apply_config(cfg)
A.assert_eq(#apply.errors, 0, "ac: config applied")
local entry = reg:get("fixture-echo")
A.check(entry ~= nil, "ac: fixture-echo entry")
local connected = vim.wait(15000, function()
  return entry.server and entry.server.state == "connected"
end)
A.check(connected, "ac: real node server connected")
A.check(tool_reg:resolve("fixture-echo/echo") ~= nil, "ac: mcp tool registered")

local v = host.new({ provider = "mock", tool_registry = tool_reg })
local chunks = {
  normalize.tool_call_started("g1", "fixture-echo/echo"),
  normalize.tool_args_delta("g1", '{"text":"hello"}'),
  normalize.tool_call_completed("g1", '{"text":"hello"}'),
}
local res1 = v:submit("first: use fixture-echo-echo", { async = true, provider_params = { chunks = chunks } })
A.check(res1.ok == true and res1.async == true, "ac: async submit accepted")
-- Full round: user + assistant(tool_call) + tool(result) + assistant(continuation).
local finished = vim.wait(30000, function()
  return v.orch.messages:len() == 4 and v.orch.session.state == "waiting_for_user"
end)
A.check(finished, "ac: continuation completed and session waiting_for_user (got msgs=" .. tostring(v.orch.messages:len()) .. " state=" .. tostring(v.orch.session.state) .. ")")
A.check(v.orch.session:is_busy() == false, "ac: session not busy")

-- Second manual submit (the UI action that previously failed).
local res2 = v:submit("second message", { async = true, provider_params = { chunks = { normalize.message_delta("second reply ") } } })
A.check(res2.rejected ~= true and res2.ok == true, "ac: second manual submit accepted (rejected=" .. tostring(res2.rejected) .. ")")
vim.wait(5000, function()
  return v.orch.messages:len() >= 6
end)
A.check(v.orch.messages:len() >= 6, "ac: second round persisted")

reg:stop_all()

if A.ok then
  print("TOOLS_ASYNC_CONTINUATION_OK")
else
  error("TOOLS_ASYNC_CONTINUATION_FAILED count=" .. #A.failures)
end
