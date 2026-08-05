-- filepath: tests/state/duplicate-submit.lua
--- Phase-2 W3 fixture: a second manual submit while busy is rejected without a
--- second request identity, a second user turn, or repeated events; the rejected
--- attempt is recorded as a replayable intent decision; a stale
--- expected_generation is rejected before the busy check.
---
--- Fixture convention: prints DUPLICATE_SUBMIT_OK on success; throws on failure.

local assert_mod = require("tests.state.lib.assert")
local recorder = require("tests.state.lib.recorder")
local events = require("maxa.runtime.events")
local orchestrator = require("maxa.runtime.orchestrator")
local schema = require("maxa.runtime.schema")

local A = assert_mod.new()

-- Deterministic provider that captures callbacks and never fires a terminal, so
-- the first submit leaves the session busy without any event-loop timing.
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

do
  local bus = events.new()
  local orch = orchestrator.new({ provider = stall_provider(), events = bus })
  local rec = recorder.new()
  rec.attach(bus)

  local first = orch:submit("first")
  A.check(first.request ~= nil, "dup: first request created")
  A.check(orch.session:is_busy(), "dup: session busy after stalled submit")

  -- Second manual submit while busy: rejected, no second identity/turn/events.
  local second = orch:submit("second")
  A.check(second.rejected == true, "dup: second submit rejected")
  A.assert_eq(second.error.code, schema.ERROR.INVALID_ARGUMENT, "dup: typed INVALID_ARGUMENT")
  A.check(second.request == nil, "dup: no second request identity")
  A.check(#orch.session.requests == 1, "dup: only one request record")
  A.check(orch.messages:len() == 1, "dup: only one user message")
  A.assert_eq(rec.count("request.submitted"), 1, "dup: no repeated request.submitted")
  A.assert_eq(rec.count("response.completed"), 0, "dup: no terminal events")

  -- The rejected attempt is recorded as a replayable intent decision.
  A.check(second.intent ~= nil and second.intent.decision ~= nil, "dup: rejection intent recorded")
  A.assert_eq(second.intent.decision.state, "rejected", "dup: intent decision rejected")
  A.check(second.intent.decision.request == nil, "dup: rejected decision has no request")

  -- Replaying the same intent_id returns the same rejected decision (no events).
  local third = orch:submit("third", { intent_id = second.intent.id })
  A.check(third.replayed == true, "dup: replay of rejected intent flagged")
  A.check(third.rejected == true, "dup: replay returns the rejection")
  A.assert_eq(third.error.message, second.error.message, "dup: same rejection error")
  A.assert_eq(rec.count("request.submitted"), 1, "dup: replay emits nothing")

  -- Stale expected_generation is rejected (recorded decision) before the kind
  -- dispatch: the boundary check runs while the session is still busy.
  local stale = orch:submit("stale", { expected_generation = 99 })
  A.check(stale.rejected == true, "dup: stale expected generation rejected")
  A.check(stale.error.message:find("stale", 1, true) ~= nil, "dup: stale diagnostic message")
  A.check(stale.intent ~= nil and stale.intent.decision.state == "rejected", "dup: stale decision recorded")
end

if A.ok then
  print("DUPLICATE_SUBMIT_OK")
else
  error("DUPLICATE_SUBMIT_FAILED count=" .. #A.failures)
end
