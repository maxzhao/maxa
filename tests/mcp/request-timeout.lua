-- filepath: tests/mcp/request-timeout.lua
--- Phase-3 W3 fixture: `mcp/request-timeout` (runtime-fixture-contract).
---   * a request that never gets a response fails independently with a typed
---     TIMEOUT error after `request_timeout_ms`,
---   * the server policy retains the connection (state stays connected),
---   * subsequent calls still work (independent failure isolation),
---   * pending bookkeeping is settled (owned_count back to zero).

local assert_mod = require("tests.state.lib.assert")
local harness = require("tests.mcp.lib.harness")

local A = assert_mod.new()
local h = harness.new()

local server = h.server(h.cfg("demo", { request_timeout_ms = 1000 }))
local res, err = server:start()
A.check(err == nil, "rt: start accepted")
A.assert_eq(server.state, "connected", "rt: connected with synchronous fake")

-- tools/call will never be answered.
local proc = h.spawned[1]
proc.no_response["tools/call"] = true

local done_err
local done_result
local rid, cerr = server:call_tool("alpha", { x = 1 }, function(result, e)
  done_result = result
  done_err = e
end)
A.check(rid ~= nil and cerr == nil, "rt: call accepted")
A.assert_eq(server:owned_count(), 1, "rt: one owned request pending")
A.check(done_err == nil, "rt: not yet failed")

h.clock.advance(999)
A.check(done_err == nil, "rt: still pending before deadline")

h.clock.advance(1)
A.check(done_err ~= nil, "rt: failed after deadline")
if done_err then
  A.assert_eq(done_err.code, "timeout", "rt: typed timeout error")
  A.check(done_err.cause ~= nil and done_err.cause.reason == "request_timeout", "rt: timeout cause")
  A.check(done_err.message:find("alpha", 1, true) ~= nil, "rt: message names the request")
end
A.check(done_result == nil, "rt: no result delivered")
A.assert_eq(server:owned_count(), 0, "rt: pending settled")

-- Policy: request timeout retains the connection (no auto-restart).
A.assert_eq(server.state, "connected", "rt: connection retained (policy)")
A.assert_eq(server.generation, 1, "rt: generation unchanged")

-- Late response for the settled request is rejected with a diagnostic
-- (generation/late-response guard: old responses never reach a caller).
local late_frame = harness.encode_frame({
  jsonrpc = "2.0",
  id = rid,
  result = { content = { { type = "text", text = "late" } } },
})
proc:emit(late_frame)
local late_seen = false
if server.client then
  for _, d in ipairs(server.client:diagnostics()) do
    if d.kind == "late_response" then
      late_seen = true
    end
  end
end
A.check(late_seen, "rt: late response dropped with diagnostic")
A.check(done_result == nil and done_err ~= nil, "rt: late response never overwrote the timeout")

-- Independent failure: the next call works normally.
proc.no_response = {}
local ok_text
local rid2, cerr2 = server:call_tool("beta", {}, function(result, e)
  if not e then
    ok_text = result.content[1].text
  end
end)
A.check(rid2 ~= nil and cerr2 == nil, "rt: follow-up call accepted")
A.check(ok_text == "called:beta", "rt: follow-up call succeeded")

if A.ok then
  print("MCP_REQUEST_TIMEOUT_OK")
else
  error("MCP_REQUEST_TIMEOUT_FAILED count=" .. #A.failures)
end
