-- filepath: tests/state/tool-invalid-call.lua
--- Phase-2 W4 fixture: invalid calls produce standard tool error results and
--- STILL participate in batch completion (tool-runtime §Call lifecycle).
---   * unknown tool name            -> error result (unknown_tool)
---   * invalid JSON arguments       -> error result (invalid_args)
--- Both results are persisted (role="tool"), the batch reaches terminal
--- completed, and the chain continues exactly once.
---
--- Fixture convention: prints TOOL_INVALID_CALL_OK on success; throws on failure.

local assert_mod = require("tests.state.lib.assert")
local recorder = require("tests.state.lib.recorder")
local events = require("maxa.runtime.events")
local orchestrator = require("maxa.runtime.orchestrator")
local protocol = require("maxa.runtime.protocol")
local normalize = require("maxa.runtime.protocol.normalize")

local A = assert_mod.new()

local mock = protocol.get(protocol.providers.mock)
local calls = 0
local scripted = {
  name = "scripted-tool-invalid",
  protocol = "mock",
  capabilities = mock.capabilities,
}
function scripted.stream(_, params, callbacks)
  calls = calls + 1
  local chunks
  if calls == 1 then
    chunks = {
      normalize.tool_call_started("c1", "no_such_tool"),
      normalize.tool_call_completed("c1", "{}"),
      normalize.tool_call_started("c2", "echo"),
      normalize.tool_args_delta("c2", '{"path":'),
      normalize.tool_call_completed("c2", '{"path":'), -- truncated: invalid JSON
    }
  else
    chunks = { "after errors" }
  end
  params = vim.tbl_deep_extend("force", params or {}, { chunks = chunks })
  return mock.stream(mock, params, callbacks)
end

local handlers = {
  echo = {
    mode = "sync",
    run = function(args, ctx)
      return "echo:" .. tostring(args and args.path or "?")
    end,
  },
}

do
  local bus = events.new()
  local orch = orchestrator.new({ provider = scripted, events = bus, tool_handlers = handlers })
  local rec = recorder.new()
  rec.attach(bus)

  local res = orch:submit("invalid calls", { provider_params = { chunks = {} } })
  A.assert_eq(res.terminal_state, "completed", "tic: request completed")

  -- One batch, terminal completed (invalid calls still complete the batch).
  local st = orch.session
  A.check(#st.tool_batches == 1, "tic: exactly one ToolBatch")
  local batch = st.tool_batches[1]
  A.assert_eq(batch.terminal.state, "completed", "tic: batch completed despite invalid calls")
  A.check(#batch.calls == 2, "tic: two calls tracked")

  -- Both results persisted as error tool messages (one message per call_id).
  local stack = orch.messages
  A.assert_eq(stack:len(), 5, "tic: user+assistant+tool+tool+assistant")
  local t1 = stack:get(3)
  local t2 = stack:get(4)
  A.assert_eq(t1.role, "tool", "tic: first tool message")
  A.assert_eq(t2.role, "tool", "tic: second tool message")

  -- c1: unknown tool -> standard error result.
  A.assert_eq(t1.content[1].call_id, "c1", "tic: c1 result call_id")
  A.assert_eq(t1.content[1].status, "error", "tic: c1 error status")
  A.check(t1.content[1].is_error == true, "tic: c1 is_error")
  A.check(t1.content[1].content:find("unknown tool", 1, true) ~= nil, "tic: c1 content mentions unknown tool")

  -- c2: invalid JSON arguments -> standard error result.
  A.assert_eq(t2.content[1].call_id, "c2", "tic: c2 result call_id")
  A.assert_eq(t2.content[1].status, "error", "tic: c2 error status")
  A.check(t2.content[1].is_error == true, "tic: c2 is_error")
  A.check(t2.content[1].content:find("invalid", 1, true) ~= nil, "tic: c2 content mentions invalid arguments")

  -- Exactly one continuation; per-call finished events for both calls.
  A.assert_eq(calls, 2, "tic: exactly two provider calls")
  A.assert_eq(rec.count("tool_call.finished"), 2, "tic: tool_call.finished per call")
  A.assert_eq(rec.count("tool_batch.finished"), 1, "tic: tool_batch.finished once")
  A.assert_eq(rec.count("request.submitted"), 2, "tic: two submits total")
end

if A.ok then
  print("TOOL_INVALID_CALL_OK")
else
  error("TOOL_INVALID_CALL_FAILED count=" .. #A.failures)
end
