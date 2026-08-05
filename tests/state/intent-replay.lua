-- filepath: tests/state/intent-replay.lua
--- Phase-2 W3 fixture: replaying the same intent_id returns the existing
--- decision/request (same request object reference) and NEVER sends a second
--- provider request (counted through a counting mock wrapper). The stack and
--- the event stream stay untouched by the replay.
---
--- Fixture convention: prints INTENT_REPLAY_OK on success; throws on failure.

local assert_mod = require("tests.state.lib.assert")
local recorder = require("tests.state.lib.recorder")
local events = require("maxa.runtime.events")
local orchestrator = require("maxa.runtime.orchestrator")
local protocol = require("maxa.runtime.protocol")

local A = assert_mod.new()

-- Counting wrapper around the unchanged mock provider (mock behavior intact).
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

do
  local bus = events.new()
  local orch = orchestrator.new({ provider = counting, events = bus })
  local rec = recorder.new()
  rec.attach(bus)

  local first = orch:submit("hello", {
    intent_id = "intent-1",
    provider_params = { chunks = { "one" } },
  })
  A.assert_eq(first.terminal_state, "completed", "replay: first submit completed")
  A.assert_eq(calls, 1, "replay: provider called once for the first submit")
  A.check(first.intent ~= nil and first.intent.id == "intent-1", "replay: intent id recorded")

  -- Replay: same intent_id -> same request reference, no provider request.
  local second = orch:submit("hello", { intent_id = "intent-1" })
  A.check(second.replayed == true, "replay: second submit replayed")
  A.check(second.request == first.request, "replay: same request object reference")
  A.assert_eq(second.terminal_state, "completed", "replay: terminal state from decision")
  A.check(second.ok == true, "replay: ok from decision")
  A.check(second.error == nil and second.rejected == nil, "replay: no rejection")

  A.assert_eq(calls, 1, "replay: provider NOT called again")
  A.check(#orch.session.requests == 1, "replay: one request record")
  A.check(#orch.session.intents == 1, "replay: one intent record")
  A.assert_eq(rec.count("request.submitted"), 1, "replay: one request.submitted event")
  A.assert_eq(rec.count("response.completed"), 1, "replay: one response.completed event")
  A.check(orch.messages:len() == 2, "replay: stack untouched (no second user turn)")
end

if A.ok then
  print("INTENT_REPLAY_OK")
else
  error("INTENT_REPLAY_FAILED count=" .. #A.failures)
end
