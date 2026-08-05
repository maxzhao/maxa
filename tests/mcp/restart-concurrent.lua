-- filepath: tests/mcp/restart-concurrent.lua
--- Phase-3 W3 fixture: `mcp/restart-concurrent` (runtime-fixture-contract).
---   * restart runs under ONE operation owner (stop + start in one op),
---   * a concurrent restart request joins the in-flight operation
---     ({ joined = true }) and never spawns a second process,
---   * generation and capabilities_revision bump exactly once per restart,
---   * state events follow stopping,stopped,starting,connected exactly once.

local assert_mod = require("tests.state.lib.assert")
local harness = require("tests.mcp.lib.harness")

local A = assert_mod.new()
local h = harness.new()
local rec = harness.recorder(h)

local server = h.server(h.cfg("demo"))
local res, err = server:start()
A.check(err == nil, "rc: start accepted")
A.assert_eq(server.state, "connected", "rc: connected")
A.assert_eq(h.spawned_by_id["demo"], 1, "rc: one spawn for the first connection")
A.assert_eq(server.generation, 1, "rc: generation 1")

-- The restart's new process answers slowly so the op stays observable.
h.spawn_configs[2] = { respond_delay = 200 }

local res1, err1 = server:restart()
A.check(err1 == nil, "rc: restart accepted")
A.check(res1 ~= nil and res1.joined == false, "rc: first restart is the owner")
A.assert_eq(server.state, "starting", "rc: restart in flight (delayed initialize)")
A.assert_eq(h.spawned_by_id["demo"], 2, "rc: restart spawned exactly one new process")
A.assert_eq(h.tool_reg:count(), 0, "rc: capabilities removed during restart")

-- Concurrent restart joins the owner; no third process.
local res2, err2 = server:restart()
A.check(err2 == nil, "rc: concurrent restart accepted")
A.check(res2 ~= nil and res2.joined == true, "rc: concurrent restart joins in-flight owner")
A.assert_eq(h.spawned_by_id["demo"], 2, "rc: no third process (single owner)")

-- Let the restart complete (initialize at +200, tools/list at +400).
h.clock.advance(200)
A.assert_eq(server.state, "starting", "rc: initialize landed, tools/list pending")
h.clock.advance(200)
A.assert_eq(server.state, "connected", "rc: restart completed")
A.assert_eq(h.spawned_by_id["demo"], 2, "rc: still exactly two spawns total")
A.assert_eq(server.generation, 2, "rc: generation bumped once")
A.assert_eq(server.capabilities_revision, 2, "rc: capability revision bumped once")
A.assert_eq(h.tool_reg:count(), 2, "rc: capabilities re-published once")

-- State event sequence (exactly one full cycle).
local seq = {}
for _, item in ipairs(rec.items) do
  if item.event == "mcp.server_state" and not item.payload.aggregate then
    seq[#seq + 1] = item.payload.state
  end
end
A.assert_eq(
  table.concat(seq, ","),
  "starting,connected,stopping,stopped,starting,connected",
  "rc: state event sequence for one restart cycle"
)

-- The joined restart did not emit its own transition events.
local stopping_count = 0
for _, item in ipairs(rec.items) do
  if item.event == "mcp.server_state" and not item.payload.aggregate and item.payload.state == "stopping" then
    stopping_count = stopping_count + 1
  end
end
A.assert_eq(stopping_count, 1, "rc: one stopping event despite concurrent restart")

if A.ok then
  print("MCP_RESTART_CONCURRENT_OK")
else
  error("MCP_RESTART_CONCURRENT_FAILED count=" .. #A.failures)
end
