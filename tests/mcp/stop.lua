-- filepath: tests/mcp/stop.lua
--- Phase-3 W3 fixture: `mcp/stop` (runtime-fixture-contract).
---   * pending requests are cancelled/failed with a typed CANCELLED error,
---   * the process is terminated (process handle closed),
---   * capabilities are removed (tool registry empty),
---   * the `stopped` state event fires exactly once (stopping + stopped),
---   * new calls are blocked while stopped; stop is idempotent.

local assert_mod = require("tests.state.lib.assert")
local harness = require("tests.mcp.lib.harness")

local A = assert_mod.new()
local h = harness.new()
local rec = harness.recorder(h)

local server = h.server(h.cfg("demo"))
local res, err = server:start()
A.check(err == nil, "stop: start accepted")
A.assert_eq(server.state, "connected", "stop: connected")
A.assert_eq(h.tool_reg:count(), 2, "stop: capabilities published")

-- Leave one tools/call pending when stop is requested.
local proc = h.spawned[1]
proc.no_response["tools/call"] = true
local done_err
local rid, cerr = server:call_tool("alpha", {}, function(result, e)
  done_err = e
end)
A.check(rid ~= nil and cerr == nil, "stop: pending call issued")
A.assert_eq(server:owned_count(), 1, "stop: one pending request")

local sres = server:stop()
A.check(sres ~= nil and sres.joined == false, "stop: stop executed")
A.assert_eq(server.state, "stopped", "stop: final state stopped")

-- Pending request cancelled with a typed error (ToolBatch cannot hang).
A.check(done_err ~= nil, "stop: pending settled")
if done_err then
  A.assert_eq(done_err.code, "cancelled", "stop: typed cancelled error")
  A.check(done_err.cause ~= nil and done_err.cause.reason == "stop", "stop: cancellation reason")
end
A.assert_eq(server:owned_count(), 0, "stop: no owned requests left")

-- Process terminated.
A.check(proc.closed == true, "stop: process handle closed")
A.check(server.client == nil, "stop: client reaped")

-- Capabilities removed.
A.assert_eq(h.tool_reg:count(), 0, "stop: capabilities removed from tool registry")

-- Cancellation notification reached the server side.
A.check(#proc.cancelled == 1, "stop: notifications/cancelled sent once")

-- State events: exactly one stopping and exactly one stopped.
local seq = {}
for _, item in ipairs(rec.items) do
  if item.event == "mcp.server_state" and not item.payload.aggregate then
    seq[#seq + 1] = item.payload.state
  end
end
A.assert_eq(table.concat(seq, ","), "starting,connected,stopping,stopped", "stop: state event sequence")
local stopped_count = 0
for _, item in ipairs(rec.items) do
  if item.event == "mcp.server_state" and not item.payload.aggregate and item.payload.state == "stopped" then
    stopped_count = stopped_count + 1
  end
end
A.assert_eq(stopped_count, 1, "stop: stopped state event exactly once")

-- New calls blocked while stopped.
local rid2, cerr2 = server:call_tool("alpha", {}, function() end)
A.check(rid2 == nil and cerr2 ~= nil, "stop: new calls blocked")
if cerr2 then
  A.assert_eq(cerr2.code, "invalid_request", "stop: typed invalid_request")
end

-- Stop is idempotent.
local sres2 = server:stop()
A.check(sres2 ~= nil and sres2.already == true, "stop: second stop is a no-op")

if A.ok then
  print("MCP_STOP_OK")
else
  error("MCP_STOP_FAILED count=" .. #A.failures)
end
