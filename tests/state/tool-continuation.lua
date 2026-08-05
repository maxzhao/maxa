-- filepath: tests/state/tool-continuation.lua
--- Phase-2 W4 fixture: a completed response with tool calls runs one ToolBatch,
--- persists every tool result as role="tool" messages BEFORE the batch barrier
--- and BEFORE the continuation request, and fires exactly one automatic
--- continuation request.
---
--- Assertions (runtime-fixture-contract state/tool-continuation):
---   * assistant tool_call part persisted;
---   * exactly one ToolBatch entity, terminal completed;
---   * all results persisted (tool message precedes the continuation assistant
---     message on the stack);
---   * exactly one continuation request (provider call count == 2);
---   * event order: tool_call.finished -> tool_batch.finished -> continuation
---     request.submitted; tool_batch.finished exactly once.
---
--- Fixture convention: prints TOOL_CONTINUATION_OK on success; throws on failure.

local assert_mod = require("tests.state.lib.assert")
local recorder = require("tests.state.lib.recorder")
local events = require("maxa.runtime.events")
local orchestrator = require("maxa.runtime.orchestrator")
local protocol = require("maxa.runtime.protocol")
local normalize = require("maxa.runtime.protocol.normalize")

local A = assert_mod.new()

-- Scripted provider: call 1 emits one tool call (echo), call 2 emits plain text.
local mock = protocol.get(protocol.providers.mock)
local calls = 0
local scripted = {
  name = "scripted-tool",
  protocol = "mock",
  capabilities = mock.capabilities,
}
function scripted.stream(_, params, callbacks)
  calls = calls + 1
  local chunks
  if calls == 1 then
    chunks = {
      normalize.tool_call_started("c1", "echo"),
      normalize.tool_args_delta("c1", '{"path":'),
      normalize.tool_args_delta("c1", '"x"}'),
      normalize.tool_call_completed("c1", '{"path":"x"}'),
    }
  else
    chunks = { "final answer" }
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

  local res = orch:submit("use echo", { provider_params = { chunks = {} } })
  A.assert_eq(res.terminal_state, "completed", "tc: first request terminal completed")

  -- Exactly one ToolBatch, terminal completed, one call, result success.
  local st = orch.session
  A.check(#st.tool_batches == 1, "tc: exactly one ToolBatch")
  local batch = st.tool_batches[1]
  A.check(batch ~= nil and batch.terminal ~= nil, "tc: batch terminal")
  A.assert_eq(batch.terminal.state, "completed", "tc: batch completed")
  A.check(#batch.calls == 1, "tc: one call in batch")
  A.assert_eq(batch.calls[1].call_id, "c1", "tc: call id")
  A.assert_eq(batch.calls[1].name, "echo", "tc: call name")

  -- Request lifecycle: first request completed through the tool_pending phase.
  A.check(#st.requests == 2, "tc: two requests (manual + continuation)")
  A.assert_eq(st.requests[1].intent, "manual", "tc: request 1 manual")
  A.assert_eq(st.requests[2].intent, "automatic", "tc: request 2 automatic continuation")
  A.assert_eq(calls, 2, "tc: exactly two provider calls (one continuation)")

  -- Message stack: user -> assistant(tool_call) -> tool(result) -> assistant.
  local stack = orch.messages
  A.assert_eq(stack:len(), 4, "tc: user+assistant+tool+assistant messages")
  A.assert_eq(stack:get(1).role, "user", "tc: msg 1 user")
  local asst = stack:get(2)
  A.assert_eq(asst.role, "assistant", "tc: msg 2 assistant")
  A.check(asst.content ~= nil and #asst.content == 1, "tc: assistant has one part (tool_call)")
  A.assert_eq(asst.content[1].type, "tool_call", "tc: part type tool_call")
  A.assert_eq(asst.content[1].call_id, "c1", "tc: tool_call part call_id")
  A.assert_eq(asst.content[1].name, "echo", "tc: tool_call part name")
  A.assert_eq(asst.content[1].arguments, '{"path":"x"}', "tc: tool_call part args")
  local tool_msg = stack:get(3)
  A.assert_eq(tool_msg.role, "tool", "tc: msg 3 tool")
  A.check(tool_msg.content ~= nil and #tool_msg.content == 1, "tc: tool msg one part")
  A.assert_eq(tool_msg.content[1].type, "tool_result", "tc: tool_result part")
  A.assert_eq(tool_msg.content[1].call_id, "c1", "tc: tool_result call_id")
  A.assert_eq(tool_msg.content[1].status, "success", "tc: tool_result status success")
  A.assert_eq(tool_msg.content[1].content, "echo:x", "tc: tool_result content")
  A.check(tool_msg.content[1].is_error == false, "tc: tool_result is_error false")
  local cont = stack:get(4)
  A.assert_eq(cont.role, "assistant", "tc: msg 4 assistant (continuation)")
  A.assert_eq(cont.content[1].text, "final answer", "tc: continuation text")

  -- Results persisted BEFORE the continuation request (stack order) AND before
  -- the barrier events: tool_call.finished -> tool_batch.finished -> second
  -- request.submitted.
  local function find_event(name, from)
    for i = from or 1, #rec.names do
      if rec.names[i] == name then
        return i
      end
    end
    return nil
  end
  local i_cf = find_event("tool_call.finished")
  local i_bf = find_event("tool_batch.finished")
  local i_sub1 = find_event("request.submitted")
  local i_sub2 = find_event("request.submitted", i_sub1 + 1)
  A.check(i_cf ~= nil, "tc: tool_call.finished emitted")
  A.check(i_bf ~= nil, "tc: tool_batch.finished emitted")
  A.check(i_sub2 ~= nil, "tc: second request.submitted emitted")
  A.check(i_cf < i_bf and i_bf < i_sub2, "tc: call finished -> batch finished -> continuation")
  A.assert_eq(rec.count("tool_batch.finished"), 1, "tc: tool_batch.finished exactly once")
  A.assert_eq(rec.count("tool_call.finished"), 1, "tc: tool_call.finished once per call")
  A.assert_eq(rec.count("request.submitted"), 2, "tc: two request.submitted total")

  -- tool_call.finished payload carries the runtime result status.
  local cf_item = rec.items[i_cf]
  A.assert_eq(cf_item.payload.status, "success", "tc: tool_call.finished status")
  A.assert_eq(cf_item.payload.batch_id, batch.id, "tc: tool_call.finished batch_id")
end

if A.ok then
  print("TOOL_CONTINUATION_OK")
else
  error("TOOL_CONTINUATION_FAILED count=" .. #A.failures)
end
