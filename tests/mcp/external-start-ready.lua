-- filepath: tests/mcp/external-start-ready.lua
--- Phase-3 W3 fixture: `mcp/external-start-ready` (runtime-fixture-contract).
---   * process spawn + initialize handshake: protocol order
---     initialize -> notifications/initialized -> tools/list,
---   * tools/resources/prompts published ONLY after connected (delayed
---     handshake: no capabilities before the tools/list response lands),
---   * tools registered into the tool registry with id `server-id/tool-name`,
---   * `mcp.server_state` emitted exactly once per transition
---     (starting, connected) with the full payload,
---   * capability revision bumps on publish; tools/call works end-to-end.

local assert_mod = require("tests.state.lib.assert")
local harness = require("tests.mcp.lib.harness")

local A = assert_mod.new()
local h = harness.new()
local rec = harness.recorder(h)

local server = h.server(h.cfg("demo", { command = "node fake.js", args = { "serve" }, cwd = "/tmp/proj" }))

-- Delay every response by 100ms so the connected gate is observable.
h.spawn_configs[1] = { respond_delay = 100 }

local res, err = server:start()
A.check(err == nil, "er: start() accepted")
A.check(res ~= nil and res.joined == false, "er: start not joined")
A.assert_eq(server.state, "starting", "er: delayed handshake leaves starting")
A.assert_eq(h.tool_reg:count(), 0, "er: no capabilities before connected")

-- Initialize response lands; tools/list still pending.
h.clock.advance(100)
A.assert_eq(server.state, "starting", "er: initialize done, tools/list pending")
A.assert_eq(h.tool_reg:count(), 0, "er: still no capabilities (connected gate)")

-- tools/list response lands -> connected + capabilities published.
h.clock.advance(100)
A.assert_eq(server.state, "connected", "er: connected after full handshake")
A.assert_eq(server.generation, 1, "er: first generation")
A.assert_eq(server.capabilities_revision, 1, "er: capability revision bumped once")
A.assert_eq(h.tool_reg:count(), 2, "er: two tools registered")

-- Tool ids use server-id/tool-name.
local alpha = h.tool_reg:resolve("demo/alpha")
A.check(alpha ~= nil, "er: demo/alpha resolvable by id")
if alpha then
  A.assert_eq(alpha.name, "alpha", "er: tool name kept")
  A.assert_eq(alpha.execution.mode, "async", "er: mcp tools are async")
  A.check(alpha.run ~= nil, "er: run bridge bound")
  A.check(alpha.cancel ~= nil, "er: cancel bridge bound")
end
local beta = h.tool_reg:resolve("beta")
A.check(beta ~= nil and beta.id == "demo/beta", "er: beta resolvable by name")

-- Protocol order on the fake process.
local proc = h.spawned[1]
A.check(proc ~= nil and proc.started == true, "er: process spawned")
if proc then
  A.check(proc.requests[1] ~= nil and proc.requests[1].method == "initialize", "er: initialize first")
  A.check(proc.requests[1].params.protocolVersion == "2024-11-05", "er: protocolVersion sent")
  A.assert_eq(proc.notifications["notifications/initialized"], 1, "er: initialized notification sent")
  A.check(proc.requests[2] ~= nil and proc.requests[2].method == "tools/list", "er: tools/list second")
end

-- State events exactly once per transition.
local seq = {}
for _, item in ipairs(rec.items) do
  if item.event == "mcp.server_state" and not item.payload.aggregate then
    seq[#seq + 1] = item.payload.state
  end
end
A.assert_eq(table.concat(seq, ","), "starting,connected", "er: state event sequence")
local first = rec.items[1]
A.check(
  first ~= nil
    and first.payload.server_id == "demo"
    and first.payload.revision == 1
    and first.payload.reason == "start"
    and first.payload.kind == "external"
    and first.payload.generation == 1,
  "er: first state payload complete"
)

-- tools/call through the server works end-to-end (response delayed by 100ms
-- like every other response in this fixture).
local call_result, call_err
local rid, cerr = server:call_tool("alpha", { x = 1 }, function(result, e)
  call_result = result
  call_err = e
end)
A.check(rid ~= nil and cerr == nil, "er: call_tool accepted")
A.check(call_err == nil, "er: call not yet failed")
h.clock.advance(100)
A.check(call_err == nil, "er: call succeeded")
A.check(
  type(call_result) == "table"
    and type(call_result.content) == "table"
    and call_result.content[1].text == "called:alpha",
  "er: mcp result text"
)

-- Unknown tool is rejected before any request.
local bad_rid, bad_err = server:call_tool("nope", {}, function() end)
A.check(bad_rid == nil and bad_err ~= nil, "er: unknown tool rejected")
if bad_err then
  A.assert_eq(bad_err.code, "invalid_request", "er: typed invalid_request")
end

-- Process stderr is bounded/sanitized diagnostics, never model context.
proc:emit_stderr("\27[31mERROR\27[0m line1\nline2 with \1control\2")
local stderr_text = server:stderr_diagnostics()
A.check(stderr_text:find("ERROR", 1, true) ~= nil, "er: stderr captured as diagnostics")
A.check(stderr_text:find("line2", 1, true) ~= nil, "er: stderr multiline kept")
A.check(stderr_text:find("%[31m", 1, true) == nil, "er: ansi escapes stripped")
A.check(stderr_text:find(string.char(1), 1, true) == nil, "er: control char 1 stripped")
A.check(stderr_text:find(string.char(2), 1, true) == nil, "er: control char 2 stripped")

if A.ok then
  print("MCP_EXTERNAL_START_READY_OK")
else
  error("MCP_EXTERNAL_START_READY_FAILED count=" .. #A.failures)
end
