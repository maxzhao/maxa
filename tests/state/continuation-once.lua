-- filepath: tests/state/continuation-once.lua
--- Phase-2 W5 fixture: a chained tool conversation (mock script: tool_call ->
--- tool_call -> text) continues EXACTLY once per completed batch — two
--- continuations total. Asserts the W5 decision point wiring:
---   * continuation.decided emitted once per durable key, after
---     tool_batch.finished and before the next request.submitted;
---   * session.loop iteration == 2, decisions hold both continue keys;
---   * no runaway loop (finite scripted chain; sync mode stack recursion is
---     bounded by the script, per W4 risk note).
---
--- Fixture convention: prints CONTINUATION_ONCE_OK on success; throws.

local assert_mod = require("tests.state.lib.assert")
local recorder = require("tests.state.lib.recorder")
local events = require("maxa.runtime.events")
local orchestrator = require("maxa.runtime.orchestrator")
local protocol = require("maxa.runtime.protocol")
local normalize = require("maxa.runtime.protocol.normalize")

local A = assert_mod.new()
local mock = protocol.get(protocol.providers.mock)

-- Scripted provider: call 1 -> tool_call(echo c1); call 2 -> tool_call(echo c2);
-- call 3 -> plain text (chain ends).
local calls = 0
local scripted = {
  name = "scripted-chain-2",
  protocol = "mock",
  capabilities = mock.capabilities,
}
function scripted.stream(_, params, callbacks)
  calls = calls + 1
  local chunks
  if calls == 1 then
    chunks = {
      normalize.tool_call_started("c1", "echo"),
      normalize.tool_call_completed("c1", '{"path":"a"}'),
    }
  elseif calls == 2 then
    chunks = {
      normalize.tool_call_started("c2", "echo"),
      normalize.tool_call_completed("c2", '{"path":"b"}'),
    }
  else
    chunks = { "chain done" }
  end
  params = vim.tbl_deep_extend("force", params or {}, { chunks = chunks })
  return mock.stream(mock, params, callbacks)
end

local handlers = {
  echo = {
    mode = "sync",
    run = function(args)
      return "echo:" .. tostring(args and args.path or "?")
    end,
  },
}

do
  local bus = events.new()
  local orch = orchestrator.new({ provider = scripted, events = bus, tool_handlers = handlers })
  local rec = recorder.new()
  rec.attach(bus)

  local res = orch:submit("chain", { provider_params = { chunks = {} } })
  A.assert_eq(res.terminal_state, "completed", "co: chain terminal completed")
  A.assert_eq(calls, 3, "co: exactly three provider calls (two continuations)")
  A.assert_eq(rec.count("request.submitted"), 3, "co: manual + two automatic submits")

  -- Two batches, both terminal completed.
  local st = orch.session
  A.assert_eq(#st.tool_batches, 2, "co: exactly two tool batches")
  A.assert_eq(st.tool_batches[1].terminal.state, "completed", "co: batch 1 completed")
  A.assert_eq(st.tool_batches[2].terminal.state, "completed", "co: batch 2 completed")
  A.assert_eq(rec.count("tool_batch.finished"), 2, "co: tool_batch.finished twice")
  A.assert_eq(rec.count("tool_call.finished"), 2, "co: tool_call.finished twice")

  -- Decision events: exactly two, one per durable continue key.
  A.assert_eq(rec.count("continuation.decided"), 2, "co: continuation.decided twice")
  local dec_items = {}
  for i, name in ipairs(rec.names) do
    if name == "continuation.decided" then
      dec_items[#dec_items + 1] = rec.items[i]
    end
  end
  A.assert_eq(dec_items[1].payload.decision_kind, "continue", "co: decision 1 continue")
  A.assert_eq(dec_items[2].payload.decision_kind, "continue", "co: decision 2 continue")
  A.check(dec_items[1].payload.decision_key ~= dec_items[2].payload.decision_key, "co: durable keys distinct")
  A.check(dec_items[1].payload.tool_batch_id == st.tool_batches[1].id, "co: decision 1 batch")
  A.check(dec_items[2].payload.tool_batch_id == st.tool_batches[2].id, "co: decision 2 batch")

  -- Event order per continuation: tool_call.finished -> tool_batch.finished ->
  -- continuation.decided -> next request.submitted.
  local function find(name, from)
    for i = from or 1, #rec.names do
      if rec.names[i] == name then
        return i
      end
    end
    return nil
  end
  local bf1 = find("tool_batch.finished")
  local cd1 = find("continuation.decided")
  local sub2 = find("request.submitted", 2)
  local bf2 = find("tool_batch.finished", bf1 + 1)
  local cd2 = find("continuation.decided", cd1 + 1)
  local sub3 = find("request.submitted", sub2 + 1)
  A.check(bf1 < cd1 and cd1 < sub2, "co: batch1 finished -> decided -> submit2")
  A.check(bf2 < cd2 and cd2 < sub3, "co: batch2 finished -> decided -> submit3")

  -- AgentLoop minimal state: iteration 2; decisions hold both continue keys;
  -- loop parked (waiting_for_user) after the final text-only completion.
  A.assert_eq(st.loop.iteration, 2, "co: loop iteration == 2")
  A.assert_eq(st.loop.state, "waiting_for_user", "co: loop parked after text completion")
  A.check(st.loop.decisions[dec_items[1].payload.decision_key] ~= nil, "co: decision 1 persisted")
  A.check(st.loop.decisions[dec_items[2].payload.decision_key] ~= nil, "co: decision 2 persisted")

  -- Requests: manual + automatic + automatic; user trace exactly one.
  A.assert_eq(#st.requests, 3, "co: three requests")
  A.assert_eq(st.requests[1].intent, "manual", "co: request 1 manual")
  A.assert_eq(st.requests[2].intent, "automatic", "co: request 2 automatic")
  A.assert_eq(st.requests[3].intent, "automatic", "co: request 3 automatic")
  local user_count = 0
  for msg in orch.messages:iter() do
    if msg.role == "user" then
      user_count = user_count + 1
    end
  end
  A.assert_eq(user_count, 1, "co: single user boundary")

  -- Results persisted before the next continuation (stack order): each batch's
  -- tool message precedes the next assistant message.
  A.assert_eq(orch.messages:len(), 6, "co: user+a1+t1+a2+t2+a3 (6 messages)")
  local m5 = orch.messages:get(5)
  A.check(m5 ~= nil and m5.role == "tool" and m5.content[1].call_id == "c2", "co: second tool result persisted")
  local m6 = orch.messages:get(6)
  A.check(m6 ~= nil and m6.role == "assistant" and m6.content[1].text == "chain done", "co: final assistant text")
end

if A.ok then
  print("CONTINUATION_ONCE_OK")
else
  error("CONTINUATION_ONCE_FAILED count=" .. #A.failures)
end
