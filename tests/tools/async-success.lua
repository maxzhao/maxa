-- filepath: tests/tools/async-success.lua
--- Phase-3 W2 fixture: async task identity/owner exposed; completion accepted
--- exactly once; late completion ignored with a recorded diagnostic; owner
--- validation (session/request/generation double check) rejects mismatches
--- (fixture contract tool/async-success; async-lifecycle spec).
---   * task identity { id, owner={session_id,request_id,batch_id}, generation }
---     is exposed on the call,
---   * task.complete CAS: first terminal outcome wins, duplicate completion is
---     ignored and recorded (diagnostics: late_completion / owner_mismatch),
---   * poll/is_cancelled are owner-gated and non-mutating,
---   * tool_call.finished / tool_batch.finished fire exactly once.
---
--- Fixture convention: prints TOOLS_ASYNC_SUCCESS_OK on success; throws on failure.

local assert_mod = require("tests.state.lib.assert")
local recorder = require("tests.state.lib.recorder")
local registry_mod = require("maxa.runtime.tools.registry")
local task_mod = require("maxa.runtime.tools.task")
local harness = require("tests.tools.lib.harness")

local A = assert_mod.new()

do
  local reg = registry_mod.new()
  reg:register({
    id = "demo/long",
    name = "long",
    description = "async tool that keeps its task",
    input_schema = { type = "object" },
    execution = { mode = "async" },
    run = function()
      return nil -- keeps the executor-owned task; completes later
    end,
  })
  local exec, h = harness.new({
    registry = reg,
    calls = {
      { call_id = "c1", name = "long", arguments = "{}" },
    },
  })
  local rec = recorder.new()
  rec.attach(h.bus)

  local res = exec:run_all()
  A.check(res.complete == false, "as: async call still running after run_all")
  local call = h.batch.calls[1]
  local task = call.task
  A.check(task ~= nil, "as: executor task identity exposed")

  -- Identity: id / owner / generation.
  A.check(type(task.id) == "string" and task.id:match("^task:") ~= nil, "as: task id present: " .. tostring(task.id))
  A.assert_eq(task.owner.session_id, "s-tools", "as: owner session_id")
  A.assert_eq(task.owner.request_id, "r-tools", "as: owner request_id")
  A.check(task.owner.batch_id ~= nil, "as: owner batch_id present")
  A.assert_eq(task.generation, 1, "as: task generation = owning request generation")
  A.check(task.state == "running", "as: task starts running")

  -- poll before completion: non-mutating, running, no result.
  local pre = task.poll()
  A.check(pre ~= nil and pre.is_terminal == false, "as: poll pre-completion not terminal")
  A.assert_eq(pre.state, "running", "as: poll pre-completion state")
  A.check(pre.result == nil, "as: poll pre-completion no result")

  -- Complete once -> accepted (CAS first terminal wins).
  local done = task.complete("hello world")
  A.check(done == true, "as: first completion accepted")
  A.assert_eq(call.state, "succeeded", "as: call succeeded")
  A.assert_eq(task.state, "succeeded", "as: task state succeeded")
  A.check(task_mod.is_terminal(task), "as: task terminal after completion")
  A.assert_eq(call.result.content, "hello world", "as: result content on the call")
  A.assert_eq(h.stack:len(), 1, "as: one tool message persisted")
  A.assert_eq(h.batch.terminal.state, "completed", "as: batch completed")

  -- Duplicate completion -> ignored + diagnostic; nothing mutated.
  local done2 = task.complete("second try")
  A.check(done2 == false, "as: duplicate completion ignored")
  A.assert_eq(call.result.content, "hello world", "as: first result unchanged")
  A.assert_eq(h.stack:len(), 1, "as: no extra persisted message")
  A.check(#task.diagnostics >= 1 and task.diagnostics[1].reason == "late_completion", "as: late completion diagnostic recorded")
  A.assert_eq(task.diagnostics[1].op, "complete", "as: diagnostic op complete")
  A.assert_eq(task.diagnostics[1].detail.state, "succeeded", "as: diagnostic detail state")

  -- Owner validation: session mismatch rejected before any mutation.
  local ok3 = task.complete("stale", { session_id = "other-session", request_id = "r-tools", generation = 1 })
  A.check(ok3 == false, "as: owner-mismatched completion rejected")
  local d3 = task.diagnostics[#task.diagnostics]
  A.assert_eq(d3.reason, "owner_mismatch", "as: owner mismatch diagnostic")
  A.assert_eq(d3.detail.cause.field, "session_id", "as: mismatch field session_id")

  -- Owner validation: request mismatch rejected.
  local ok4 = task.complete("stale", { session_id = "s-tools", request_id = "r-other", generation = 1 })
  A.check(ok4 == false, "as: request-mismatched completion rejected")
  local d4 = task.diagnostics[#task.diagnostics]
  A.assert_eq(d4.reason, "owner_mismatch", "as: request mismatch diagnostic")
  A.assert_eq(d4.detail.cause.field, "request_id", "as: mismatch field request_id")

  -- Owner validation: task generation mismatch rejected (async-lifecycle).
  local ok5 = task.complete("stale", { session_id = "s-tools", request_id = "r-tools", generation = 2 })
  A.check(ok5 == false, "as: generation-mismatched completion rejected")
  local d5 = task.diagnostics[#task.diagnostics]
  A.assert_eq(d5.reason, "owner_mismatch", "as: generation mismatch diagnostic")
  A.assert_eq(d5.detail.cause.field, "generation", "as: mismatch field generation")

  -- Correct owner still cannot complete a terminal task (CAS holds).
  local ok6 = task.complete("owner", { session_id = "s-tools", request_id = "r-tools", generation = 1 })
  A.check(ok6 == false, "as: late completion with correct owner still ignored")
  A.assert_eq(call.result.content, "hello world", "as: content still unchanged after all rejections")
  A.assert_eq(h.stack:len(), 1, "as: persisted message count unchanged")

  -- poll / is_cancelled: terminal snapshot; owner-gated reads.
  local snap = task.poll()
  A.check(snap ~= nil, "as: poll returns snapshot")
  A.assert_eq(snap.state, "succeeded", "as: poll state")
  A.assert_eq(snap.result.content, "hello world", "as: poll result")
  A.check(snap.is_terminal == true, "as: poll terminal")
  A.check(task.is_cancelled() == false, "as: not cancelled")
  local snap_bad, poll_err = task.poll({ session_id = "nope" })
  A.check(snap_bad == nil and poll_err ~= nil and poll_err.code == "owner_mismatch", "as: poll owner-gated")
  local cancelled_bad, canc_err = task.is_cancelled({ generation = 9 })
  A.check(cancelled_bad == false and canc_err ~= nil and canc_err.code == "owner_mismatch", "as: is_cancelled owner-gated")

  -- Events: exactly one per-call finish + one batch finish.
  A.assert_eq(rec.count("tool_call.finished"), 1, "as: tool_call.finished exactly once")
  A.assert_eq(rec.count("tool_batch.finished"), 1, "as: tool_batch.finished exactly once")
end

if A.ok then
  print("TOOLS_ASYNC_SUCCESS_OK")
else
  error("TOOLS_ASYNC_SUCCESS_FAILED count=" .. #A.failures)
end
