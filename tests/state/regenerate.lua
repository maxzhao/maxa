-- filepath: tests/state/regenerate.lua
--- Phase-2 W3 fixture: regenerate preserves the last user boundary, archives the
--- prior assistant attempt (removed from the stack), rebuilds a new request
--- WITHOUT a new user message, and rejects when no user boundary exists.
---
--- Fixture convention: prints REGENERATE_OK on success; throws on failure.

local assert_mod = require("tests.state.lib.assert")
local recorder = require("tests.state.lib.recorder")
local events = require("maxa.runtime.events")
local orchestrator = require("maxa.runtime.orchestrator")
local protocol = require("maxa.runtime.protocol")

local A = assert_mod.new()

local mock = protocol.get(protocol.providers.mock)

do
  local bus = events.new()
  local orch = orchestrator.new({ provider = mock, events = bus })
  local rec = recorder.new()
  rec.attach(bus)

  local first = orch:submit("hello", { provider_params = { chunks = { "first reply" } } })
  A.assert_eq(first.terminal_state, "completed", "regen: seed completed")
  A.check(orch.messages:len() == 2, "regen: seed stack user+assistant")

  local regen = orch:submit("", { kind = "regenerate", provider_params = { chunks = { "second reply" } } })
  A.assert_eq(regen.terminal_state, "completed", "regen: regenerate completed")
  A.assert_eq(regen.request.intent, "regenerate", "regen: request intent regenerate")
  A.check(regen.archived ~= nil and #regen.archived == 1, "regen: old assistant archived")
  A.assert_eq(regen.archived[1].role, "assistant", "regen: archived message is assistant")
  A.assert_eq(regen.archived[1].content[1].text, "first reply", "regen: archived old reply")

  -- Stack replaced: user boundary preserved, old assistant gone, new reply in.
  local stack = orch.messages
  A.assert_eq(stack:len(), 2, "regen: stack replaced (user + new assistant)")
  A.assert_eq(stack:get(1).role, "user", "regen: user boundary first")
  A.assert_eq(stack:get(1).content[1].text, "hello", "regen: user boundary preserved")
  A.assert_eq(stack:get(2).role, "assistant", "regen: assistant reply")
  A.assert_eq(stack:get(2).content[1].text, "second reply", "regen: old reply replaced")
  A.check(#orch.session.requests == 2, "regen: new request created")
  A.assert_eq(rec.count("request.submitted"), 2, "regen: one request.submitted per submit")
end

-- No user boundary: regenerate is rejected and the stack stays untouched.
do
  local bus = events.new()
  local orch = orchestrator.new({ provider = mock, events = bus })
  local res = orch:submit("", { kind = "regenerate" })
  A.check(res.rejected == true, "regen-empty: rejected without user boundary")
  A.check(res.request == nil, "regen-empty: no request")
  A.check(orch.messages:len() == 0, "regen-empty: stack untouched")
end

if A.ok then
  print("REGENERATE_OK")
else
  error("REGENERATE_FAILED count=" .. #A.failures)
end
