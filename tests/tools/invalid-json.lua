-- filepath: tests/tools/invalid-json.lua
--- Phase-3 W1 fixture: malformed JSON arguments produce a standard invalid-call
--- error result that still participates in batch completion (tool-runtime
--- §Call lifecycle; fixture contract tool/invalid-json).
---   * the registry-resolved handler is NOT executed for invalid JSON,
---   * each error result is persisted paired to its call_id,
---   * the batch reaches terminal "completed", tool_call.finished fires per
---     call and tool_batch.finished fires exactly once.
---
--- Fixture convention: prints TOOLS_INVALID_JSON_OK on success; throws on failure.

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
  execution = { mode = "sync" },
  run = function(args)
    echo_runs = echo_runs + 1
    return "echo:" .. args.path
  end,
})
A.check(def ~= nil, "ij: registry registration succeeded (" .. tostring(derr and derr.message) .. ")")

local exec, h = harness.new({
  registry = reg,
  calls = {
    { call_id = "c1", name = "echo", arguments = '{"path":' }, -- truncated JSON
    { call_id = "c2", name = "echo", arguments = "not json" }, -- not JSON at all
  },
})
local rec = recorder.new()
rec.attach(h.bus)
local terminal_summaries = {}
exec.on_terminal = function(_, summary)
  terminal_summaries[#terminal_summaries + 1] = summary
end
local res = exec:run_all()

A.check(res.complete == true, "ij: batch reached terminal")
A.assert_eq(h.batch.terminal.state, "completed", "ij: batch completed despite invalid JSON")
A.check(#h.batch.calls == 2, "ij: two calls tracked")
A.check(echo_runs == 0, "ij: registry handler never executed for invalid JSON")

-- Per-call persisted error results, paired to call identity.
A.assert_eq(h.stack:len(), 2, "ij: two persisted tool messages")
local t1 = h.stack:get(1)
local t2 = h.stack:get(2)
A.assert_eq(t1.content[1].call_id, "c1", "ij: c1 result paired")
A.assert_eq(t1.content[1].status, "error", "ij: c1 error status")
A.check(t1.content[1].is_error == true, "ij: c1 is_error")
A.check(t1.content[1].content:find("invalid_args", 1, true) ~= nil, "ij: c1 standard invalid_args code")
A.assert_eq(t2.content[1].call_id, "c2", "ij: c2 result paired")
A.check(t2.content[1].content:find("invalid_args", 1, true) ~= nil, "ij: c2 standard invalid_args code")

-- Events: per-call finished + barrier exactly once; batch summary has errors.
A.assert_eq(rec.count("tool_call.finished"), 2, "ij: tool_call.finished per call")
A.assert_eq(rec.count("tool_batch.finished"), 1, "ij: tool_batch.finished exactly once")
A.assert_eq(#terminal_summaries, 1, "ij: on_terminal called exactly once")
A.check(terminal_summaries[1][1].is_error == true, "ij: c1 in summary is error")
A.check(terminal_summaries[1][2].is_error == true, "ij: c2 in summary is error")

if A.ok then
  print("TOOLS_INVALID_JSON_OK")
else
  error("TOOLS_INVALID_JSON_FAILED count=" .. #A.failures)
end
