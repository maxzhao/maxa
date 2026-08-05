-- filepath: tests/state/tool-only-response.lua
--- Phase-2 W4 fixture: a provider response with tool calls and NO text must
--- not be reported as an empty/failed response — the ToolBatch executes
--- normally and the chain continues exactly once.
---
--- Assertions (runtime-fixture-contract state/tool-only-response):
---   * no response.failed / empty-failure event;
---   * ToolBatch begins (tool_batch.started) and executes the call;
---   * result persisted; exactly one continuation request.
---
--- Fixture convention: prints TOOL_ONLY_RESPONSE_OK on success; throws on failure.

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
  name = "scripted-tool-only",
  protocol = "mock",
  capabilities = mock.capabilities,
}
function scripted.stream(_, params, callbacks)
  calls = calls + 1
  local chunks
  if calls == 1 then
    -- Tool calls only: no message_delta / reasoning / usage events.
    chunks = {
      normalize.tool_call_started("c1", "echo"),
      normalize.tool_call_completed("c1", '{"path":"x"}'),
    }
  else
    chunks = { "done" }
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

  local res = orch:submit("tool only", { provider_params = { chunks = {} } })
  A.assert_eq(res.terminal_state, "completed", "tor: request completed (no empty failure)")
  A.assert_eq(rec.count("response.failed"), 0, "tor: no response.failed event")

  -- The batch started and executed the call.
  local st = orch.session
  A.check(#st.tool_batches == 1, "tor: exactly one ToolBatch")
  local batch = st.tool_batches[1]
  A.assert_eq(batch.terminal.state, "completed", "tor: batch completed")
  A.assert_eq(batch.calls[1].state, "succeeded", "tor: call succeeded")

  -- Assistant message has only the tool_call part (no text part).
  local stack = orch.messages
  A.assert_eq(stack:len(), 4, "tor: user+assistant+tool+assistant")
  local asst = stack:get(2)
  A.check(asst.content ~= nil and #asst.content == 1, "tor: assistant single part")
  A.assert_eq(asst.content[1].type, "tool_call", "tor: assistant part is tool_call")

  -- Result persisted with success content.
  local tool_msg = stack:get(3)
  A.assert_eq(tool_msg.role, "tool", "tor: tool message")
  A.assert_eq(tool_msg.content[1].status, "success", "tor: result success")
  A.assert_eq(tool_msg.content[1].content, "echo:x", "tor: result content")

  -- Exactly one continuation.
  A.assert_eq(calls, 2, "tor: exactly two provider calls")
  A.assert_eq(rec.count("request.submitted"), 2, "tor: two submits (manual + automatic)")
  A.assert_eq(rec.count("tool_batch.started"), 1, "tor: tool_batch.started once")
  A.assert_eq(rec.count("tool_batch.finished"), 1, "tor: tool_batch.finished once")
end

if A.ok then
  print("TOOL_ONLY_RESPONSE_OK")
else
  error("TOOL_ONLY_RESPONSE_FAILED count=" .. #A.failures)
end
