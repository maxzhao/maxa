-- filepath: tests/state/tool-async-cancel-late.lua
--- Phase-2 W4 fixture: async tool tasks are owner-scoped (session/request/
--- batch); orchestrator:stop() cancels the running batch (handler.cancel
--- propagation, drain -> terminal cancelled, results persisted, NO
--- continuation); a LATE task.complete() after cancellation does NOT override
--- the cancelled result (compare-and-set).
---
--- Assertions (runtime-fixture-contract state/tool-async-cancel-late):
---   * sync submit returns tool_pending=true (batch running, request tool_pending);
---   * stop cancels: handler.cancel called, call cancelled, batch drained and
---     terminal cancelled, request terminal cancelled;
---   * persisted result stays cancelled/error after the late completion;
---   * exactly one tool_batch.finished; no continuation (one request total);
---   * late complete() is rejected (CAS) without mutation.
---
--- Fixture convention: prints TOOL_ASYNC_CANCEL_LATE_OK on success; throws.

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
  name = "scripted-tool-async",
  protocol = "mock",
  capabilities = mock.capabilities,
}
function scripted.stream(_, params, callbacks)
  calls = calls + 1
  params = vim.tbl_deep_extend("force", params or {}, {
    chunks = {
      normalize.tool_call_started("c1", "slow"),
      normalize.tool_call_completed("c1", "{}"),
    },
  })
  return mock.stream(mock, params, callbacks)
end

do
  local task_ref = nil
  local cancel_called = false
  local handlers = {
    slow = {
      mode = "async",
      run = function(args, ctx, task)
        task_ref = task
        return task -- task identity
      end,
      cancel = function()
        cancel_called = true
      end,
    },
  }

  local bus = events.new()
  local orch = orchestrator.new({ provider = scripted, events = bus, tool_handlers = handlers })
  local rec = recorder.new()
  rec.attach(bus)

  -- Sync submit: the async handler leaves the batch running.
  local res = orch:submit("async tool", { provider_params = { chunks = {} } })
  A.check(res.tool_pending == true, "acl: sync submit reports tool_pending")
  A.check(res.error_record == nil, "acl: tool_pending is not a failure")
  A.check(task_ref ~= nil, "acl: handler received the task identity")
  A.check(task_ref.owner ~= nil and task_ref.owner.session_id == orch.session.id, "acl: task owner session scope")
  A.check(orch._active_executor ~= nil, "acl: executor active")
  local batch = orch.session.tool_batches[#orch.session.tool_batches]
  A.check(batch ~= nil and batch.state == "running", "acl: batch running")
  A.assert_eq(calls, 1, "acl: one provider call so far")

  -- Hard stop: cancels the batch (propagates to the handler, drains, persists).
  local stopped = orch:stop("test cancel")
  A.check(stopped == true, "acl: stop performed")
  A.check(cancel_called == true, "acl: handler.cancel propagated")
  A.check(task_ref.is_cancelled() == true, "acl: task reports cancelled")
  A.check(orch._active_executor == nil or orch._active_executor:is_terminal(), "acl: executor terminal")
  A.assert_eq(batch.terminal.state, "cancelled", "acl: batch terminal cancelled")
  A.assert_eq(orch.session.requests[1].terminal.state, "cancelled", "acl: request terminal cancelled")
  A.assert_eq(rec.count("tool_batch.draining"), 1, "acl: tool_batch.draining once")
  A.assert_eq(rec.count("tool_batch.finished"), 1, "acl: tool_batch.finished once")
  A.assert_eq(calls, 1, "acl: no continuation after cancel")

  -- Persisted result reflects the cancellation (error, mentions cancelled).
  local stack = orch.messages
  local tool_msg = stack:last()
  A.assert_eq(tool_msg.role, "tool", "acl: tool message persisted")
  A.assert_eq(tool_msg.content[1].status, "error", "acl: cancelled result is error")
  A.check(tool_msg.content[1].is_error == true, "acl: cancelled result is_error")
  A.check(tool_msg.content[1].content:find("cancelled", 1, true) ~= nil, "acl: content mentions cancelled")

  -- Late completion after cancellation: CAS rejects, no mutation.
  local late = task_ref.complete("late success")
  A.check(late == false, "acl: late complete rejected (CAS)")
  A.assert_eq(batch.terminal.state, "cancelled", "acl: batch stays cancelled")
  A.assert_eq(orch.session.requests[1].terminal.state, "cancelled", "acl: request stays cancelled")
  A.check(
    stack:last().content[1].content:find("cancelled", 1, true) ~= nil,
    "acl: result unchanged after late complete"
  )
  A.assert_eq(calls, 1, "acl: no new provider call after late complete")
  A.assert_eq(#orch.session.requests, 1, "acl: no continuation request created")
  A.assert_eq(rec.count("tool_batch.finished"), 1, "acl: barrier still exactly once")
  A.assert_eq(rec.count("request.submitted"), 1, "acl: one request.submitted total")
end

if A.ok then
  print("TOOL_ASYNC_CANCEL_LATE_OK")
else
  error("TOOL_ASYNC_CANCEL_LATE_FAILED count=" .. #A.failures)
end
