-- filepath: tests/state/manual-submit-success.lua
--- Phase-2 W3 fixture: one manual submit end-to-end with the exact W8 event
--- order, one user turn, session returning to waiting_for_user, and the W3
--- submit-intent record (kind/expected_generation/input_revision captured).
---
--- Fixture convention: prints MANUAL_SUBMIT_SUCCESS_OK on success; throws on
--- failure (the tests/state runner records the failure and continues).

local assert_mod = require("tests.state.lib.assert")
local recorder = require("tests.state.lib.recorder")
local events = require("maxa.runtime.events")
local orchestrator = require("maxa.runtime.orchestrator")
local protocol = require("maxa.runtime.protocol")

local A = assert_mod.new()

do
  local bus = events.new()
  local orch = orchestrator.new({
    provider = protocol.get(protocol.providers.mock),
    events = bus,
    model = "mock-model",
  })
  local rec = recorder.new()
  rec.attach(bus)
  local res = orch:submit("hello", {
    expected_generation = 0, -- the session starts at generation 0 (legal boundary)
    input_revision = "in-v1",
    context_revision = "ctx-v1",
    provider_params = { chunks = { "Hello ", "world" } },
  })

  -- Sync outcome + exact W8 event order.
  A.assert_eq(res.terminal_state, "completed", "manual: terminal completed")
  A.check(res.ok == true, "manual: ok")
  A.assert_eq(
    rec.names_concat(),
    "request.submitted,request.started,response.started,message.delta,message.delta,response.completed",
    "manual: exact W8 event order"
  )

  -- W3 intent record: kind + captured expectations + terminal decision.
  A.check(res.intent ~= nil, "manual: intent carried on result")
  A.assert_eq(res.intent.kind, "manual", "manual: intent kind")
  A.assert_eq(res.intent.expected_generation, 0, "manual: intent expected generation")
  A.assert_eq(res.intent.input_revision, "in-v1", "manual: input revision captured")
  A.assert_eq(res.intent.context_revision, "ctx-v1", "manual: context revision captured")
  A.check(res.intent.decision ~= nil and res.intent.decision.state == "completed", "manual: decision completed")
  A.check(res.intent.decision.request == res.request, "manual: decision references the request")

  -- Session state: one request, back to waiting_for_user.
  local st = orch.session
  A.assert_eq(st.state, "waiting_for_user", "manual: session waiting_for_user")
  A.check(#st.requests == 1, "manual: exactly one request")
  A.assert_eq(st.requests[1].intent, "manual", "manual: request intent")
  A.assert_eq(st.requests[1].generation, 1, "manual: request generation")
  A.assert_eq(st.requests[1].id, res.request.id, "manual: result request identity")
  A.check(st:is_idle() and not st:is_busy(), "manual: session idle after completion")

  -- Message stack: exactly one user turn + one assistant turn.
  local stack = orch.messages
  A.assert_eq(stack:len(), 2, "manual: one user + one assistant")
  A.assert_eq(stack:get(1).role, "user", "manual: first message user")
  A.assert_eq(stack:get(1).content[1].text, "hello", "manual: user text")
  A.assert_eq(stack:get(2).role, "assistant", "manual: second message assistant")
  A.assert_eq(stack:get(2).content[1].text, "Hello world", "manual: assistant text")
end

if A.ok then
  print("MANUAL_SUBMIT_SUCCESS_OK")
else
  error("MANUAL_SUBMIT_SUCCESS_FAILED count=" .. #A.failures)
end
