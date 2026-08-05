-- filepath: tests/state/stop-vs-cancel.lua
--- Phase-2 W6 fixture: the separated control operations. `cancel` hard-cancels
--- the current work and returns the session to waiting_for_user (recoverable,
--- NO suppression marker); `stop` = cancel + hard-stop marker + session ->
--- stopped (terminal-ish: further submits are rejected, close still works).
--- Both suppress any continuation; the difference is the session boundary and
--- the suppression marker.
---
--- Assertions (runtime-fixture-contract state/stop-vs-cancel):
---   * cancel: batch + request terminal cancelled, session waiting_for_user,
---     _stop_requested == false, decision terminate(request_cancelled), no
---     continuation, a manual submit afterwards completes (recoverable);
---   * stop: batch + request terminal cancelled, session stopped,
---     _stop_requested == true, no continuation, idempotent second stop,
---     a manual submit afterwards is rejected (terminal error), close works.
---
--- Fixture convention: prints STOP_VS_CANCEL_OK on success; throws.

local assert_mod = require("tests.state.lib.assert")
local recorder = require("tests.state.lib.recorder")
local events = require("maxa.runtime.events")
local orchestrator = require("maxa.runtime.orchestrator")
local protocol = require("maxa.runtime.protocol")
local normalize = require("maxa.runtime.protocol.normalize")

local A = assert_mod.new()

local mock = protocol.get(protocol.providers.mock)

-- Scripted provider factory: call 1 emits one tool call; later calls text.
---@param counter table { n = integer }
---@return table provider
local function make_scripted(counter)
  local scripted = {
    name = "scripted-stop-vs-cancel",
    protocol = "mock",
    capabilities = mock.capabilities,
  }
  function scripted.stream(_, params, callbacks)
    counter.n = counter.n + 1
    if counter.n == 1 then
      params = vim.tbl_deep_extend("force", params or {}, {
        chunks = {
          normalize.tool_call_started("c1", "slow"),
          normalize.tool_call_completed("c1", "{}"),
        },
      })
    else
      params = vim.tbl_deep_extend("force", params or {}, { chunks = { "after cancel" } })
    end
    return mock.stream(mock, params, callbacks)
  end
  return scripted
end

--- Find the first recorded event item by name.
---@param rec table recorder
---@param name string
---@return table|nil item
local function find_event(rec, name)
  for _, item in ipairs(rec.items) do
    if item.event == name then
      return item
    end
  end
  return nil
end

-- Scenario A: cancel -> hard cancel, session recoverable, no marker.
do
  local counter = { n = 0 }
  local task_ref = nil
  local handlers = {
    slow = {
      mode = "async",
      run = function(args, ctx, task)
        task_ref = task
        return task
      end,
      cancel = function() end,
    },
  }
  local bus = events.new()
  local orch = orchestrator.new({ provider = make_scripted(counter), events = bus, tool_handlers = handlers })
  local rec = recorder.new()
  rec.attach(bus)

  local res = orch:submit("cancel me", { provider_params = { chunks = {} } })
  A.check(res.tool_pending == true, "svc-cancel: submit reports tool_pending")

  local cancelled = orch:cancel("fixture cancel")
  A.check(cancelled == true, "svc-cancel: cancel performed")
  A.check(orch._stop_requested == false, "svc-cancel: no suppression marker")
  A.assert_eq(orch.session.state, "waiting_for_user", "svc-cancel: session recoverable (waiting_for_user)")
  local batch = orch.session.tool_batches[1]
  A.assert_eq(batch.terminal.state, "cancelled", "svc-cancel: batch cancelled")
  A.assert_eq(orch.session.requests[1].terminal.state, "cancelled", "svc-cancel: request cancelled")
  A.assert_eq(counter.n, 1, "svc-cancel: no continuation")
  A.assert_eq(orch.session.loop.state, "waiting_for_user", "svc-cancel: loop parked")

  -- Decision boundary: terminate(request_cancelled).
  local decided = find_event(rec, "continuation.decided")
  A.check(decided ~= nil, "svc-cancel: continuation.decided emitted")
  A.assert_eq(decided.payload.decision_kind, "terminate", "svc-cancel: decision terminate")
  A.assert_eq(decided.payload.decision_reason, "request_cancelled", "svc-cancel: terminate reason")

  -- Manual submit after cancel works (recoverable).
  local res2 = orch:submit("after cancel", { provider_params = { chunks = {} } })
  A.assert_eq(res2.terminal_state, "completed", "svc-cancel: manual submit after cancel completes")
  A.assert_eq(counter.n, 2, "svc-cancel: second provider call")
end

-- Scenario B: stop -> cancel + hard-stop marker + session stopped (terminal-ish).
do
  local counter = { n = 0 }
  local task_ref = nil
  local handlers = {
    slow = {
      mode = "async",
      run = function(args, ctx, task)
        task_ref = task
        return task
      end,
      cancel = function() end,
    },
  }
  local bus = events.new()
  local orch = orchestrator.new({ provider = make_scripted(counter), events = bus, tool_handlers = handlers })
  local rec = recorder.new()
  rec.attach(bus)

  local res = orch:submit("stop me", { provider_params = { chunks = {} } })
  A.check(res.tool_pending == true, "svc-stop: submit reports tool_pending")

  local stopped = orch:stop("fixture stop")
  A.check(stopped == true, "svc-stop: stop performed")
  A.check(orch._stop_requested == true, "svc-stop: suppression marker set")
  A.assert_eq(orch.session.state, "stopped", "svc-stop: session stopped")
  local batch = orch.session.tool_batches[1]
  A.assert_eq(batch.terminal.state, "cancelled", "svc-stop: batch cancelled")
  A.assert_eq(orch.session.requests[1].terminal.state, "cancelled", "svc-stop: request cancelled")
  A.assert_eq(counter.n, 1, "svc-stop: no continuation")
  A.assert_eq(orch.session.loop.state, "waiting_for_user", "svc-stop: loop parked (no continuation)")

  -- Decision boundary: terminate(request_cancelled) — the session-stop effect
  -- marked the request cancelled; the stop marker yields wait(stop) only when
  -- the work completes despite the cancel (decision-table row 2, unit-tested
  -- in state/decision-table).
  local decided = find_event(rec, "continuation.decided")
  A.check(decided ~= nil, "svc-stop: continuation.decided emitted")
  A.assert_eq(decided.payload.decision_kind, "terminate", "svc-stop: decision terminate")
  A.assert_eq(decided.payload.decision_reason, "request_cancelled", "svc-stop: terminate reason")

  -- Idempotent: a second stop has nothing to cancel.
  A.check(orch:stop() == false, "svc-stop: stop idempotent")

  -- A stopped session rejects further submits (terminal-ish; close still works).
  local res2 = orch:submit("after stop", { provider_params = { chunks = {} } })
  A.check(res2.rejected == true, "svc-stop: submit after stop rejected")
  A.check(res2.error ~= nil and res2.error.terminal == true, "svc-stop: stopped rejection is terminal")
  A.check(orch:close() == true, "svc-stop: close from stopped")
end

if A.ok then
  print("STOP_VS_CANCEL_OK")
else
  error("STOP_VS_CANCEL_FAILED count=" .. #A.failures)
end
