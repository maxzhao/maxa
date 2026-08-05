-- filepath: tests/state/automatic-submit.lua
--- Phase-2 W3 fixture: automatic continuation submits.
---   A. idle boundary: an automatic submit creates a request (intent
---      "automatic") WITHOUT a manual user turn and without duplicating the
---      request; exactly one provider call per submit.
---   B. non-idle boundary: while busy the automatic submit is rejected with a
---      recorded intent decision — no request, no user turn, no events.
---
--- Fixture convention: prints AUTOMATIC_SUBMIT_OK on success; throws on failure.

local assert_mod = require("tests.state.lib.assert")
local recorder = require("tests.state.lib.recorder")
local events = require("maxa.runtime.events")
local orchestrator = require("maxa.runtime.orchestrator")
local protocol = require("maxa.runtime.protocol")

local A = assert_mod.new()

local mock = protocol.get(protocol.providers.mock)
local calls = 0
local counting = {
  name = "counting-mock",
  protocol = "mock",
  capabilities = mock.capabilities,
}
function counting.stream(_, params, callbacks)
  calls = calls + 1
  return mock.stream(mock, params, callbacks)
end

local function stall_provider()
  return {
    name = "stall",
    protocol = "stall",
    capabilities = { vision = false, tools = false, reasoning = false },
    stream = function()
      return {
        active = true,
        cancel = function()
          return false
        end,
      }
    end,
  }
end

-------------------------------------------------------------------------------
-- A. Automatic at an idle boundary
-------------------------------------------------------------------------------
do
  local bus = events.new()
  local orch = orchestrator.new({ provider = counting, events = bus })

  local manual = orch:submit("hello", { provider_params = { chunks = { "manual reply" } } })
  A.assert_eq(manual.terminal_state, "completed", "auto: manual seed completed")
  A.assert_eq(calls, 1, "auto: one provider call so far")

  local auto = orch:submit("", { kind = "automatic", provider_params = { chunks = { "auto reply" } } })
  A.assert_eq(auto.terminal_state, "completed", "auto: automatic submit completed")
  A.assert_eq(auto.request.intent, "automatic", "auto: request intent automatic")
  A.assert_eq(auto.intent.kind, "automatic", "auto: intent kind automatic")
  A.assert_eq(calls, 2, "auto: exactly one provider call per submit")

  A.check(#orch.session.requests == 2, "auto: two requests (manual + automatic)")
  local stack = orch.messages
  local user_count, assistant_count = 0, 0
  for msg in stack:iter() do
    if msg.role == "user" then
      user_count = user_count + 1
    end
    if msg.role == "assistant" then
      assistant_count = assistant_count + 1
    end
  end
  A.assert_eq(user_count, 1, "auto: no second user turn created")
  A.assert_eq(assistant_count, 2, "auto: two assistant replies")
  A.assert_eq(stack:get(1).content[1].text, "hello", "auto: original user boundary intact")
end

-------------------------------------------------------------------------------
-- B. Automatic while busy: rejected decision, no request, no events
-------------------------------------------------------------------------------
do
  local bus = events.new()
  local orch = orchestrator.new({ provider = stall_provider(), events = bus })
  local rec = recorder.new()
  rec.attach(bus)

  local manual = orch:submit("first")
  A.check(manual.request ~= nil, "auto-busy: first request created")
  A.check(orch.session:is_busy(), "auto-busy: session busy")

  local auto = orch:submit("", { kind = "automatic" })
  A.check(auto.rejected == true, "auto-busy: automatic rejected while busy")
  A.check(auto.request == nil, "auto-busy: no request created")
  A.check(#orch.session.requests == 1, "auto-busy: no duplicate request")
  A.check(orch.messages:len() == 1, "auto-busy: no user turn added")
  A.assert_eq(rec.count("request.submitted"), 1, "auto-busy: no repeated events")
  A.check(auto.intent ~= nil and auto.intent.decision.state == "rejected", "auto-busy: intent decision rejected")
  A.check(auto.error ~= nil and auto.error.message:find("automatic", 1, true) ~= nil, "auto-busy: policy error message")
end

if A.ok then
  print("AUTOMATIC_SUBMIT_OK")
else
  error("AUTOMATIC_SUBMIT_FAILED count=" .. #A.failures)
end
