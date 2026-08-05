-- filepath: tests/mcp/external-start-fail.lua
--- Phase-3 W3 fixture: `mcp/external-start-fail` (runtime-fixture-contract).
---   * failed state carries a typed cause (process exit during startup),
---   * NO partial capability exposure (tool registry stays empty),
---   * process handle is reaped (client/process_handle cleared),
---   * `mcp.server_state` emitted exactly once per transition
---     (starting, failed),
---   * a second scenario: rpc error from initialize also lands in failed with a
---     typed protocol cause.

local assert_mod = require("tests.state.lib.assert")
local harness = require("tests.mcp.lib.harness")

local A = assert_mod.new()

-- Scenario A: process exits immediately after spawn (during startup).
do
  local h = harness.new()
  local rec = harness.recorder(h)
  h.spawn_configs[1] = {
    on_spawn = function(proc)
      proc:emit_exit(1)
    end,
  }
  local server = h.server(h.cfg("demo"))
  local res, err = server:start()
  A.check(err == nil, "sf-a: start() accepted")
  A.assert_eq(server.state, "failed", "sf-a: failed after process exit")
  A.check(server.last_error ~= nil, "sf-a: typed cause present")
  if server.last_error then
    A.assert_eq(server.last_error.code, "network", "sf-a: cause code = network")
    A.check(
      server.last_error.cause ~= nil and server.last_error.cause.reason == "process_exit",
      "sf-a: cause reason = process_exit"
    )
    A.check(server.last_error.cause.code == 1, "sf-a: cause carries exit code")
  end
  A.assert_eq(h.tool_reg:count(), 0, "sf-a: no partial capability exposure")
  local proc = h.spawned[1]
  A.check(proc ~= nil and proc.started == true, "sf-a: process was spawned")
  A.check(proc.exited == true, "sf-a: process exited")
  A.check(server.client == nil, "sf-a: client handle reaped")
  A.check(server.process_handle == nil, "sf-a: process handle reaped")
  local seq = {}
  for _, item in ipairs(rec.items) do
    if item.event == "mcp.server_state" and not item.payload.aggregate then
      seq[#seq + 1] = item.payload.state
    end
  end
  A.assert_eq(table.concat(seq, ","), "starting,failed", "sf-a: exactly starting,failed")
  A.check(server.accepting_calls == false, "sf-a: calls blocked after failure")
  -- No pending requests survive.
  A.assert_eq(server:owned_count(), 0, "sf-a: no owned requests left")
end

-- Scenario B: initialize answers with an rpc error -> failed with protocol cause.
do
  local h = harness.new()
  h.spawn_configs[1] = {
    script = {
      ["initialize"] = function()
        return nil, { code = -32603, message = "boom" }
      end,
    },
  }
  local server = h.server(h.cfg("demo"))
  server:start()
  A.assert_eq(server.state, "failed", "sf-b: failed after initialize rpc error")
  A.check(server.last_error ~= nil and server.last_error.code == "protocol", "sf-b: typed protocol cause")
  A.check(server.last_error.cause ~= nil and server.last_error.cause.reason == "rpc_error", "sf-b: rpc_error reason")
  A.assert_eq(h.tool_reg:count(), 0, "sf-b: no capabilities")
  A.check(server.client == nil, "sf-b: handle reaped")
end

-- Scenario C: startup timeout -> failed with typed timeout cause.
do
  local h = harness.new()
  h.spawn_configs[1] = {
    no_response = { ["initialize"] = true },
  }
  local server = h.server(h.cfg("demo", { startup_timeout_ms = 100 }))
  server:start()
  A.assert_eq(server.state, "starting", "sf-c: still starting before timeout")
  h.clock.advance(100)
  A.assert_eq(server.state, "failed", "sf-c: failed after startup timeout")
  A.check(server.last_error ~= nil and server.last_error.code == "timeout", "sf-c: typed timeout cause")
  A.check(server.client == nil, "sf-c: handle reaped")
end

if A.ok then
  print("MCP_EXTERNAL_START_FAIL_OK")
else
  error("MCP_EXTERNAL_START_FAIL_FAILED count=" .. #A.failures)
end
