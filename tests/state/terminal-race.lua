-- filepath: tests/state/terminal-race.lua
--- Phase-2 W5 fixture: terminal callback races and duplicate-decision safety.
--- The FIRST legal terminal transition wins; late/duplicate callbacks must not
--- mutate events/state/traces (runtime-fixture-contract terminal-race).
---
--- Scenarios:
---   A. text request: on_done() and on_error() both fire (done first) ->
---      completed exactly once, no response.failed, no duplicate trace.
---   B. cancel wins: on_error(CANCELLED) fires before on_done() -> cancelled
---      exactly once, no response.completed.
---   C. batch chain: first request carries a tool call, the late on_error for
---      the SAME request arrives after on_done -> batch executes, exactly one
---      continuation; the second (automatic) request also races and stays
---      completed once.
---   D. durable-key dedup: replaying the same batch terminal decision point
---      (same session_generation/request/batch/kind) is REJECTED with a
---      reference to the existing decision record — no repeated submit, no
---      repeated continuation.decided, no third provider call.
---   E. late stop after a terminal state cancels nothing.
---
--- Fixture convention: prints TERMINAL_RACE_OK on success; throws on failure.

local assert_mod = require("tests.state.lib.assert")
local recorder = require("tests.state.lib.recorder")
local events = require("maxa.runtime.events")
local orchestrator = require("maxa.runtime.orchestrator")
local protocol = require("maxa.runtime.protocol")
local normalize = require("maxa.runtime.protocol.normalize")
local schema = require("maxa.runtime.schema")

local A = assert_mod.new()
local mock = protocol.get(protocol.providers.mock)

-- Provider that fires on_done() then a late on_error() (both for the same
-- request). The orchestrator must accept the first terminal transition only.
local function done_then_error_provider()
  return {
    name = "race-done-then-error",
    protocol = "mock",
    capabilities = mock.capabilities,
    stream = function(_, _, callbacks)
      callbacks.on_done()
      callbacks.on_error(schema.new_error(schema.ERROR.PROVIDER, "late error after done", nil, true))
      return {
        active = true,
        cancel = function()
          return false
        end,
      }
    end,
  }
end

-- Provider that fires on_error(CANCELLED) before on_done().
local function cancel_then_done_provider()
  return {
    name = "race-cancel-then-done",
    protocol = "mock",
    capabilities = mock.capabilities,
    stream = function(_, _, callbacks)
      callbacks.on_error(schema.new_error(schema.ERROR.CANCELLED, "cancel wins", nil, true))
      callbacks.on_done()
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
-- A. done then late error (text path)
-------------------------------------------------------------------------------
do
  local bus = events.new()
  local orch = orchestrator.new({ provider = done_then_error_provider(), events = bus })
  local rec = recorder.new()
  rec.attach(bus)
  local res = orch:submit("race text")
  A.assert_eq(res.terminal_state, "completed", "A: first terminal (done) wins")
  A.assert_eq(rec.count("response.completed"), 1, "A: response.completed exactly once")
  A.assert_eq(rec.count("response.failed"), 0, "A: late error emits no response.failed")
  A.assert_eq(rec.count("response.cancelled"), 0, "A: no cancelled event")
  A.assert_eq(#orch.session.requests, 1, "A: exactly one request")
  A.assert_eq(orch.session.requests[1].terminal.state, "completed", "A: request terminal completed")
  A.check(orch.session:is_idle(), "A: session idle after terminal")
  A.assert_eq(orch.messages:len(), 2, "A: user + assistant only (no duplicate trace)")
  -- Late stop after terminal: nothing to cancel.
  A.check(orch:stop("late stop") == false, "A: late stop cancels nothing")
  A.assert_eq(rec.count("response.cancelled"), 0, "A: late stop emits nothing")
end

-------------------------------------------------------------------------------
-- B. cancel wins over a late done
-------------------------------------------------------------------------------
do
  local bus = events.new()
  local orch = orchestrator.new({ provider = cancel_then_done_provider(), events = bus })
  local rec = recorder.new()
  rec.attach(bus)
  local res = orch:submit("race cancel")
  A.assert_eq(res.terminal_state, "cancelled", "B: first terminal (cancel) wins")
  A.assert_eq(rec.count("response.cancelled"), 1, "B: response.cancelled exactly once")
  A.assert_eq(rec.count("response.completed"), 0, "B: late done emits no response.completed")
  A.assert_eq(rec.count("response.failed"), 0, "B: no failed event")
  A.assert_eq(orch.session.requests[1].terminal.state, "cancelled", "B: request terminal cancelled")
end

-------------------------------------------------------------------------------
-- C. batch chain with a late on_error racing the SAME request, plus durable-key
-- dedup (D) on the batch terminal decision point
-------------------------------------------------------------------------------
do
  local bus = events.new()
  local calls = 0
  local chain = {
    name = "race-chain",
    protocol = "mock",
    capabilities = mock.capabilities,
    stream = function(_, _, callbacks)
      calls = calls + 1
      if calls == 1 then
        callbacks.on_event(normalize.tool_call_started("c1", "echo"))
        callbacks.on_event(normalize.tool_call_completed("c1", '{"path":"x"}'))
      end
      -- Every call races: done first, then a late error for the SAME request.
      callbacks.on_done()
      callbacks.on_error(schema.new_error(schema.ERROR.PROVIDER, "late error", nil, true))
      return {
        active = true,
        cancel = function()
          return false
        end,
      }
    end,
  }
  local handlers = {
    echo = {
      mode = "sync",
      run = function(args)
        return "echo:" .. tostring(args and args.path or "?")
      end,
    },
  }
  local orch = orchestrator.new({ provider = chain, events = bus, tool_handlers = handlers })
  local rec = recorder.new()
  rec.attach(bus)
  local res = orch:submit("race chain")
  A.assert_eq(res.terminal_state, "completed", "C: chain terminal completed")
  A.assert_eq(calls, 2, "C: exactly two provider calls (one continuation)")
  A.assert_eq(rec.count("response.completed"), 2, "C: two response.completed (no duplicates)")
  A.assert_eq(rec.count("response.failed"), 0, "C: late errors never surface")
  A.assert_eq(#orch.session.requests, 2, "C: manual + automatic")
  A.assert_eq(#orch.session.tool_batches, 1, "C: exactly one batch")
  A.assert_eq(rec.count("tool_batch.finished"), 1, "C: batch finished once")
  A.assert_eq(rec.count("request.submitted"), 2, "C: two request.submitted total")
  A.assert_eq(rec.count("continuation.decided"), 1, "C: one continuation decision")

  -- D. Replay the SAME decision point (same batch terminal, same request): the
  -- durable continuation key already exists -> rejected with the existing
  -- record reference; nothing is submitted/emitted and no third provider call.
  local st = orch.session
  local cur = { request = st.requests[1], terminal = true }
  local batch = st.tool_batches[1]
  -- Re-arm the loop so the decision row is "continue" (the same row the first
  -- decision took): the existing continue key must dedupe it.
  st.loop.state = "armed"
  local before = { calls = calls, subs = rec.count("request.submitted"), dec = rec.count("continuation.decided") }
  local replay = orch:_decide_continuation(cur, batch)
  A.check(replay ~= nil and replay.replayed == true, "D: same-key second decision rejected (replayed)")
  A.check(replay.record ~= nil and type(replay.record.key) == "string", "D: existing record reference returned")
  A.assert_eq(calls, before.calls, "D: no third provider call")
  A.assert_eq(rec.count("request.submitted"), before.subs, "D: no repeated request.submitted")
  A.assert_eq(rec.count("continuation.decided"), before.dec, "D: no repeated continuation.decided")
  A.assert_eq(#st.requests, 2, "D: no duplicate request entity")
end

if A.ok then
  print("TERMINAL_RACE_OK")
else
  error("TERMINAL_RACE_FAILED count=" .. #A.failures)
end
