-- filepath: tests/state/chat-close.lua
--- Phase-2 W8 fixture: closing the chat closes every session-owned request /
--- task / timer in a DETERMINISTIC order (cancel -> terminal -> cleanup) and
--- late callbacks cannot revive the closed session.
---
--- Assertions (runtime-fixture-contract async/chat-close):
--- Scenario A (provider stream in flight):
---   * close cancels the provider handle (best-effort) FIRST while the request
---     identity is still current -> exactly one response.cancelled, request
---     terminal cancelled, then the session closes;
---   * event order is deterministic: request.submitted -> response.cancelled
---     (the terminal fires before cleanup, never after);
---   * late provider chunks / terminal callbacks after close are rejected (no
---     events, no mutation, no revival);
---   * a second close() is an idempotent no-op.
--- Scenario B (tool batch in flight):
---   * close cancels the executor (task propagation + barrier) -> batch drains
---     then reaches terminal cancelled, request terminal cancelled, exactly one
---     continuation decision (terminate — no automatic submit);
---   * deterministic order: tool_batch.draining < tool_batch.finished <
---     continuation.decided, and everything happens BEFORE session close;
---   * no new provider call, no response.cancelled (the response already
---     completed before the batch).
---
--- Fixture convention: prints CHAT_CLOSE_OK on success; throws.

local assert_mod = require("tests.state.lib.assert")
local recorder = require("tests.state.lib.recorder")
local events = require("maxa.runtime.events")
local schema = require("maxa.runtime.schema")
local orchestrator = require("maxa.runtime.orchestrator")
local protocol = require("maxa.runtime.protocol")
local normalize = require("maxa.runtime.protocol.normalize")

local A = assert_mod.new()

local mock = protocol.get(protocol.providers.mock)

-- Scenario A: close during an in-flight provider stream.
do
  local cancel_count = 0
  local callbacks_ref = nil
  local stream_calls = 0
  local scripted = {
    name = "scripted-chat-close-stream",
    protocol = "mock",
    capabilities = mock.capabilities,
  }
  function scripted.stream(_, params, callbacks)
    stream_calls = stream_calls + 1
    callbacks_ref = callbacks
    return {
      active = true,
      cancel = function()
        cancel_count = cancel_count + 1
        if cancel_count == 1 then
          callbacks.on_error(schema.new_error(schema.ERROR.CANCELLED, "stream cancelled by close", nil, true))
          return true
        end
        return false
      end,
    }
  end

  local bus = events.new()
  local orch = orchestrator.new({ provider = scripted, events = bus })
  local rec = recorder.new()
  rec.attach(bus)

  local res = orch:submit("close me", { async = true, provider_params = {} })
  A.check(res.async == true and orch:is_busy(), "cc-a: stream in flight")
  A.assert_eq(cancel_count, 0, "cc-a: no cancel before close")

  -- Close: cancel -> terminal -> cleanup.
  local changed = orch:close()
  A.check(changed == true, "cc-a: close performed")
  A.assert_eq(cancel_count, 1, "cc-a: provider cancel invoked once")
  A.assert_eq(rec.count("response.cancelled"), 1, "cc-a: response.cancelled once")
  A.assert_eq(orch.session.requests[1].terminal.state, "cancelled", "cc-a: request terminal cancelled")
  A.check(orch.session:is_closed(), "cc-a: session closed")
  A.check(orch._current == nil and orch._active_executor == nil, "cc-a: owned references cleared")

  -- Deterministic order: request.submitted -> response.cancelled -> (close).
  local order = {}
  for _, item in ipairs(rec.items) do
    if item.event ~= "session.created" then
      order[#order + 1] = item.event
    end
  end
  A.assert_eq(table.concat(order, ","), "request.submitted,response.cancelled", "cc-a: deterministic close event order")

  -- Late callbacks cannot revive the closed session.
  local before = #rec.names
  callbacks_ref.on_event(normalize.message_delta("revive?"))
  callbacks_ref.on_done()
  callbacks_ref.on_error(schema.new_error(schema.ERROR.INTERNAL, "revive?", nil, true))
  A.assert_eq(#rec.names, before, "cc-a: no events from late callbacks")
  A.assert_eq(rec.count("response.cancelled"), 1, "cc-a: terminal exactly once")
  A.assert_eq(stream_calls, 1, "cc-a: no new provider work")
  A.check(orch.session:is_closed(), "cc-a: session stays closed")

  -- Idempotent second close.
  A.check(orch:close() == false, "cc-a: second close no-op")
  A.assert_eq(cancel_count, 1, "cc-a: provider cancel still once")
  A.assert_eq(#rec.names, before, "cc-a: no events from second close")
end

-- Scenario B: close during an owned tool batch.
do
  local runs = 0
  local handlers = {
    slow = {
      mode = "async",
      run = function(args, ctx, task)
        runs = runs + 1
        return task
      end,
      cancel = function() end,
    },
  }
  local provider, calls = nil, nil
  do
    local provider_mock = {
      name = "scripted-chat-close-tools",
      protocol = "mock",
      capabilities = mock.capabilities,
    }
    local n = 0
    function provider_mock.stream(_, params, callbacks)
      n = n + 1
      params = vim.tbl_deep_extend("force", params or {}, {
        chunks = {
          normalize.tool_call_started("c1", "slow"),
          normalize.tool_call_completed("c1", "{}"),
        },
      })
      return mock.stream(mock, params, callbacks)
    end
    provider = provider_mock
    calls = function()
      return n
    end
  end

  local bus = events.new()
  local orch = orchestrator.new({ provider = provider, events = bus, tool_handlers = handlers })
  local rec = recorder.new()
  rec.attach(bus)

  local res = orch:submit("close mid-batch", { provider_params = {} })
  A.check(res.tool_pending == true, "cc-b: batch running")
  A.assert_eq(runs, 1, "cc-b: tool started")

  local changed = orch:close()
  A.check(changed == true, "cc-b: close performed")
  local batch = orch.session.tool_batches[#orch.session.tool_batches]
  A.assert_eq(batch.terminal.state, "cancelled", "cc-b: batch terminal cancelled")
  A.assert_eq(orch.session.requests[1].terminal.state, "cancelled", "cc-b: request terminal cancelled")
  A.check(orch.session:is_closed(), "cc-b: session closed")
  A.assert_eq(rec.count("tool_batch.draining"), 1, "cc-b: draining once")
  A.assert_eq(rec.count("tool_batch.finished"), 1, "cc-b: finished once")
  A.assert_eq(rec.count("tool_call.finished"), 1, "cc-b: one call terminal")

  -- Deterministic order: draining < finished < continuation.decided; the
  -- decision is terminate (no automatic continuation submit).
  local idx_drain, idx_finish, idx_decide = nil, nil, nil
  for i, item in ipairs(rec.items) do
    if item.event == "tool_batch.draining" then
      idx_drain = idx_drain or i
    elseif item.event == "tool_batch.finished" then
      idx_finish = idx_finish or i
    elseif item.event == "continuation.decided" then
      idx_decide = idx_decide or i
    end
  end
  A.check(idx_drain ~= nil and idx_finish ~= nil and idx_decide ~= nil, "cc-b: order markers present")
  A.check(idx_drain < idx_finish, "cc-b: draining before finished")
  A.check(idx_finish < idx_decide, "cc-b: finished before decision")
  local decide_item = rec.items[idx_decide]
  A.assert_eq(decide_item.payload.decision_kind, "terminate", "cc-b: decision terminate")
  A.assert_eq(rec.count("response.cancelled"), 0, "cc-b: no response.cancelled (response already completed)")
  A.assert_eq(rec.count("response.completed"), 1, "cc-b: response.completed once (before batch)")
  A.assert_eq(calls(), 1, "cc-b: no continuation submit")
  A.assert_eq(#orch.session.requests, 1, "cc-b: one request total")

  -- Late tool completion after close is rejected (CAS; executor terminal).
  local last_call = batch.calls[1]
  A.check(last_call.task == nil or last_call.task.complete("late") == false, "cc-b: late completion rejected")
  A.assert_eq(batch.terminal.state, "cancelled", "cc-b: batch stays cancelled")
  A.check(orch:close() == false, "cc-b: second close no-op")
end

if A.ok then
  print("CHAT_CLOSE_OK")
else
  error("CHAT_CLOSE_FAILED count=" .. #A.failures)
end
