-- filepath: tests/tools/async-cancel-late-result.lua
--- Phase-3 W2 fixture: late success cannot overwrite cancellation
--- (fixture contract tool/async-cancel-late-result).
---   * A. task.cancel() CAS: handler cancel invoked, task + call + batch
---        cancelled, late complete() rejected with a diagnostic and no
---        mutation of the persisted cancelled result,
---   * B. executor:cancel() batch path propagates to the running task
---        (is_cancelled/poll reflect it) and a late success still cannot
---        overwrite the cancellation,
---   * exactly one terminal event per call and one batch finish.
---
--- Fixture convention: prints TOOLS_ASYNC_CANCEL_LATE_RESULT_OK on success;
--- throws on failure.

local assert_mod = require("tests.state.lib.assert")
local recorder = require("tests.state.lib.recorder")
local registry_mod = require("maxa.runtime.tools.registry")
local harness = require("tests.tools.lib.harness")

local A = assert_mod.new()

-------------------------------------------------------------------------------
-- A. Single-task cancellation path (task.cancel)
-------------------------------------------------------------------------------
do
  local cancel_calls = 0
  local reg = registry_mod.new()
  reg:register({
    id = "demo/worker",
    name = "worker",
    description = "cancellable async tool",
    input_schema = { type = "object" },
    execution = { mode = "async", cancellable = true },
    run = function()
      return nil
    end,
    cancel = function()
      cancel_calls = cancel_calls + 1
    end,
  })
  local exec, h = harness.new({
    registry = reg,
    calls = {
      { call_id = "c1", name = "worker", arguments = "{}" },
    },
  })
  local rec = recorder.new()
  rec.attach(h.bus)
  exec:run_all()

  local task = h.batch.calls[1].task
  local ok = task.cancel("stop now")
  A.check(ok == true, "cl: task.cancel accepted")
  A.assert_eq(cancel_calls, 1, "cl: handler cancel invoked once")
  A.check(task.is_cancelled() == true, "cl: task is_cancelled")
  A.assert_eq(task.state, "cancelled", "cl: task state cancelled")
  A.assert_eq(h.batch.calls[1].state, "cancelled", "cl: call state cancelled")
  -- Per-call cancellation (task.cancel) is a per-call terminal outcome like a
  -- timeout/failure: the barrier opens with the batch completed. Only the
  -- executor-level cancel (exec:cancel) marks the batch itself cancelled.
  A.assert_eq(h.batch.terminal.state, "completed", "cl: batch completes via per-call cancellation")

  -- Late success cannot overwrite the cancellation (CAS).
  local late = task.complete("late success")
  A.check(late == false, "cl: late success rejected")
  local part = h.stack:get(1).content[1]
  A.assert_eq(part.status, "error", "cl: persisted result stays error")
  A.assert_eq(part.content, "tool error [cancelled]: stop now", "cl: persisted content stays cancelled")
  A.check(h.stack:get(1).content[1].content:find("late success", 1, true) == nil, "cl: late content never persisted")
  A.assert_eq(h.stack:len(), 1, "cl: no extra persisted message")
  local d = task.diagnostics[#task.diagnostics]
  A.assert_eq(d.reason, "late_completion", "cl: late completion diagnostic")
  A.assert_eq(d.detail.state, "cancelled", "cl: diagnostic state cancelled")

  -- Cancel after terminal: late_cancel diagnostic, no second effect.
  local ok2 = task.cancel("again")
  A.check(ok2 == false, "cl: second cancel rejected")
  A.assert_eq(cancel_calls, 1, "cl: handler cancel not invoked twice")
  A.assert_eq(task.diagnostics[#task.diagnostics].reason, "late_cancel", "cl: late cancel diagnostic")

  -- poll reflects cancellation.
  local snap = task.poll()
  A.assert_eq(snap.state, "cancelled", "cl: poll reflects cancellation")

  -- Events: one per-call finish, one batch finish, both cancelled/error.
  A.assert_eq(rec.count("tool_call.finished"), 1, "cl: tool_call.finished exactly once")
  A.assert_eq(rec.count("tool_batch.finished"), 1, "cl: tool_batch.finished exactly once")
  for _, item in ipairs(rec.items) do
    if item.event == "tool_call.finished" then
      A.assert_eq(item.payload.state, "cancelled", "cl: finished payload cancelled")
      A.check(item.payload.is_error == true, "cl: finished payload is_error")
    end
  end
end

-------------------------------------------------------------------------------
-- B. Executor-level cancellation propagation (exec:cancel) + late result
-------------------------------------------------------------------------------
do
  local cancel_calls = 0
  local reg = registry_mod.new()
  reg:register({
    id = "demo/worker2",
    name = "worker2",
    description = "cancellable async tool (batch path)",
    input_schema = { type = "object" },
    execution = { mode = "async", cancellable = true },
    run = function()
      return nil
    end,
    cancel = function()
      cancel_calls = cancel_calls + 1
    end,
  })
  local exec, h = harness.new({
    registry = reg,
    calls = {
      { call_id = "c1", name = "worker2", arguments = "{}" },
    },
  })
  exec:run_all()
  local task = h.batch.calls[1].task

  local cancelled = exec:cancel("user cancelled")
  A.check(cancelled == true, "cl: executor cancel accepted")
  A.assert_eq(cancel_calls, 1, "cl: handler cancel propagated")
  A.check(task.is_cancelled() == true, "cl: task cancelled through executor propagation")
  local snap = task.poll()
  A.assert_eq(snap.state, "cancelled", "cl: poll reflects executor cancellation")
  A.assert_eq(h.batch.terminal.state, "cancelled", "cl: batch cancelled")

  -- Late success after batch cancel: rejected; persisted result untouched.
  local late = task.complete("late success")
  A.check(late == false, "cl: late success after batch cancel rejected")
  local part = h.stack:get(1).content[1]
  A.assert_eq(part.content, "tool error [cancelled]: user cancelled", "cl: persisted content stays batch-cancelled")
  A.check(part.content:find("late success", 1, true) == nil, "cl: late content never persisted")
  A.assert_eq(task.diagnostics[#task.diagnostics].reason, "late_completion", "cl: late completion diagnostic on batch path")
  A.assert_eq(h.batch.calls[1].state, "cancelled", "cl: call state stays cancelled")
end

if A.ok then
  print("TOOLS_ASYNC_CANCEL_LATE_RESULT_OK")
else
  error("TOOLS_ASYNC_CANCEL_LATE_RESULT_FAILED count=" .. #A.failures)
end
