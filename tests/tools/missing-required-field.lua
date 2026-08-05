-- filepath: tests/tools/missing-required-field.lua
--- Phase-3 W1 fixture: schema validation failures produce a standard
--- invalid-call error result whose message contains the EXACT field path, and
--- the result is paired to the call identity (fixture contract
--- tool/missing-required-field; T-001).
---   * missing required field -> "args.path.required"
---   * wrong type              -> "args.path.type"
---   * the registry handler is NOT executed for invalid arguments,
---   * a valid call still succeeds through the same registry resolution.
---
--- Fixture convention: prints TOOLS_MISSING_REQUIRED_OK on success; throws on failure.

local assert_mod = require("tests.state.lib.assert")
local recorder = require("tests.state.lib.recorder")
local registry_mod = require("maxa.runtime.tools.registry")
local harness = require("tests.tools.lib.harness")

local A = assert_mod.new()

local echo_runs = 0
local reg = registry_mod.new()
local def, derr = reg:register({
  id = "demo/echo",
  name = "echo",
  description = "echo a path",
  input_schema = {
    type = "object",
    properties = { path = { type = "string" } },
    required = { "path" },
  },
  run = function(args)
    echo_runs = echo_runs + 1
    return "echo:" .. args.path
  end,
})
A.check(def ~= nil, "mr: registry registration succeeded (" .. tostring(derr and derr.message) .. ")")

-------------------------------------------------------------------------------
-- A. Missing required field: '{}'
-------------------------------------------------------------------------------
do
  local exec, h = harness.new({
    registry = reg,
    calls = {
      { call_id = "c1", name = "echo", arguments = "{}" },
    },
  })
  local rec = recorder.new()
  rec.attach(h.bus)
  exec:run_all()

  A.assert_eq(h.batch.terminal.state, "completed", "mr: batch completed")
  A.check(echo_runs == 0, "mr: handler not executed for missing required field")
  A.assert_eq(h.stack:len(), 1, "mr: one persisted tool message")
  local part = h.stack:get(1).content[1]
  A.assert_eq(part.call_id, "c1", "mr: result paired to call id")
  A.assert_eq(part.status, "error", "mr: error status")
  A.check(part.content:find("args.path.required", 1, true) ~= nil, "mr: exact field path in error: " .. part.content)
  A.check(part.content:find("invalid_args", 1, true) ~= nil, "mr: standard invalid_args code")
end

-------------------------------------------------------------------------------
-- B. Wrong type: '{"path":123}'
-------------------------------------------------------------------------------
do
  local exec, h = harness.new({
    registry = reg,
    calls = {
      { call_id = "c2", name = "echo", arguments = '{"path":123}' },
    },
  })
  exec:run_all()

  A.check(echo_runs == 0, "mr: handler not executed for wrong type")
  local part = h.stack:get(1).content[1]
  A.assert_eq(part.call_id, "c2", "mr: c2 result paired")
  A.check(part.content:find("args.path.type", 1, true) ~= nil, "mr: exact type path in error: " .. part.content)
end

-------------------------------------------------------------------------------
-- C. Valid call still resolves and runs through the registry
-------------------------------------------------------------------------------
do
  local exec, h = harness.new({
    registry = reg,
    calls = {
      { call_id = "c3", name = "echo", arguments = '{"path":"/tmp/x"}' },
    },
  })
  exec:run_all()

  A.assert_eq(echo_runs, 1, "mr: valid call executed the registry handler")
  local part = h.stack:get(1).content[1]
  A.assert_eq(part.status, "success", "mr: valid call success")
  A.assert_eq(part.content, "echo:/tmp/x", "mr: handler result persisted")
  A.assert_eq(h.batch.calls[1].state, "succeeded", "mr: call state succeeded")
end

if A.ok then
  print("TOOLS_MISSING_REQUIRED_OK")
else
  error("TOOLS_MISSING_REQUIRED_FAILED count=" .. #A.failures)
end
