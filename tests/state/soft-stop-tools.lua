-- filepath: tests/state/soft-stop-tools.lua
--- Phase-2 W6 fixture: a soft stop requested while a ToolBatch is executing
--- DRAINS the batch (results persisted, batch terminal completed — never
--- cancelled), suppresses the automatic continuation (decision wait + AgentLoop
--- parked), and a repeat request toggles the soft stop OFF so a later batch
--- continues normally.
---
--- Assertions (runtime-fixture-contract state/soft-stop-tools):
---   * soft_stop accepted while busy (request tool_pending, batch running);
---   * the running batch drains: terminal completed, result persisted, NO
---     response.cancelled / batch cancelled;
---   * continuation.decided wait(soft_stop) exactly once; loop + session
---     parked at waiting_for_user; no continuation request;
---   * a repeat request while armed toggles OFF (requested=false event) and a
---     following batch continues: one automatic continuation request runs.
---
--- Fixture convention: prints SOFT_STOP_TOOLS_OK on success; throws on failure.

local assert_mod = require("tests.state.lib.assert")
local recorder = require("tests.state.lib.recorder")
local events = require("maxa.runtime.events")
local orchestrator = require("maxa.runtime.orchestrator")
local protocol = require("maxa.runtime.protocol")
local normalize = require("maxa.runtime.protocol.normalize")

local A = assert_mod.new()

local mock = protocol.get(protocol.providers.mock)

-- Scripted provider factory: call 1 emits one tool call; later calls emit text.
---@param counter table { n = integer }
---@return table provider
local function make_scripted(counter)
  local scripted = {
    name = "scripted-soft-stop-tools",
    protocol = "mock",
    capabilities = mock.capabilities,
  }
  function scripted.stream(_, params, callbacks)
    counter.n = counter.n + 1
    if counter.n == 1 then
      params = vim.tbl_deep_extend("force", params or {}, {
        chunks = {
          normalize.tool_call_started("c1", "slow"),
          normalize.tool_args_delta("c1", "{}"),
          normalize.tool_call_completed("c1", "{}"),
        },
      })
    else
      params = vim.tbl_deep_extend("force", params or {}, { chunks = { "after drain" } })
    end
    return mock.stream(mock, params, callbacks)
  end
  return scripted
end

-- Scenario 1: soft stop during batch execution drains + parks the loop.
do
  local counter = { n = 0 }
  local task_ref = nil
  local handlers = {
    slow = {
      mode = "async",
      run = function(args, ctx, task)
        task_ref = task
        return task -- task identity; completion arrives via task.complete
      end,
    },
  }
  local bus = events.new()
  local orch = orchestrator.new({ provider = make_scripted(counter), events = bus, tool_handlers = handlers })
  local rec = recorder.new()
  rec.attach(bus)

  local res = orch:submit("drain tools", { provider_params = { chunks = {} } })
  A.check(res.tool_pending == true, "sst: submit reports tool_pending")
  A.check(task_ref ~= nil, "sst: async task started")
  A.check(orch.session:is_busy(), "sst: session busy while batch runs")

  -- Soft stop while the batch is running: accepted, nothing cancelled.
  local ss = orch:soft_stop()
  A.check(ss.accepted == true, "sst: soft_stop accepted while batch running")
  A.check(orch._soft_stop_requested == true, "sst: soft-stop marker set")

  -- Let the batch drain to its natural terminal (results persisted).
  task_ref.complete({ content = "echo:x" })
  local batch = orch.session.tool_batches[1]
  A.assert_eq(batch.terminal.state, "completed", "sst: batch drained (completed, not cancelled)")
  A.check(batch.calls[1].result ~= nil and batch.calls[1].result.status == "success", "sst: call result persisted")
  A.assert_eq(batch.calls[1].result.content, "echo:x", "sst: call result content")

  -- Persisted tool result on the stack (user + assistant(tool_call) + tool).
  local stack = orch.messages
  A.assert_eq(stack:len(), 3, "sst: user+assistant+tool messages")
  local tool_msg = stack:get(3)
  A.assert_eq(tool_msg.role, "tool", "sst: tool message persisted")
  A.assert_eq(tool_msg.content[1].type, "tool_result", "sst: tool_result part")
  A.assert_eq(tool_msg.content[1].status, "success", "sst: tool_result success")
  A.assert_eq(tool_msg.content[1].content, "echo:x", "sst: tool_result content")

  -- No cancellation, no continuation.
  A.assert_eq(rec.count("response.cancelled"), 0, "sst: no response.cancelled")
  A.assert_eq(rec.count("tool_batch.finished"), 1, "sst: batch finished once")
  A.assert_eq(counter.n, 1, "sst: no continuation provider call")
  A.check(#orch.session.requests == 1, "sst: exactly one request")

  -- Soft-stop request + completion events; decision wait(soft_stop).
  A.assert_eq(rec.count("chat.soft_stop_requested"), 1, "sst: soft_stop_requested once")
  A.assert_eq(rec.count("chat.soft_stop_completed"), 1, "sst: soft_stop_completed once")
  local done_item
  for _, item in ipairs(rec.items) do
    if item.event == "chat.soft_stop_completed" then
      done_item = item
      break
    end
  end
  A.check(done_item ~= nil and done_item.payload.reason == "soft_stop", "sst: completion reason soft_stop")
  local decided
  for _, item in ipairs(rec.items) do
    if item.event == "continuation.decided" then
      decided = item
      break
    end
  end
  A.check(decided ~= nil, "sst: continuation.decided emitted")
  A.assert_eq(decided.payload.decision_kind, "wait", "sst: decision wait")
  A.assert_eq(decided.payload.decision_reason, "soft_stop", "sst: decision reason soft_stop")
  A.assert_eq(orch.session.state, "waiting_for_user", "sst: session waiting_for_user")
  A.assert_eq(orch.session.loop.state, "waiting_for_user", "sst: loop parked")

  -- Manual submit after the drain works.
  local res2 = orch:submit("again", { provider_params = { chunks = {} } })
  A.assert_eq(res2.terminal_state, "completed", "sst: manual submit after drain completes")
  A.assert_eq(counter.n, 2, "sst: second provider call")
end

-- Scenario 2: repeat soft_stop while armed toggles OFF -> the batch continues.
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
    },
  }
  local bus = events.new()
  local orch = orchestrator.new({ provider = make_scripted(counter), events = bus, tool_handlers = handlers })
  local rec = recorder.new()
  rec.attach(bus)

  local res = orch:submit("toggle test", { provider_params = { chunks = {} } })
  A.check(res.tool_pending == true, "sst2: submit reports tool_pending")
  local ss1 = orch:soft_stop()
  A.check(ss1.accepted == true, "sst2: first request accepted")
  local ss2 = orch:soft_stop()
  A.check(ss2.toggled_off == true, "sst2: repeat request toggles off")
  A.check(orch._soft_stop_requested == false, "sst2: flag cleared by toggle")

  -- Drain: the toggle-off batch continues normally (decision continue).
  task_ref.complete({ content = "echo:y" })
  A.assert_eq(orch.session.tool_batches[1].terminal.state, "completed", "sst2: batch completed")
  A.assert_eq(counter.n, 2, "sst2: continuation ran after toggle-off")
  A.check(#orch.session.requests == 2, "sst2: two requests (manual + continuation)")
  A.assert_eq(orch.session.requests[2].intent, "automatic", "sst2: continuation automatic")

  -- Events: requested then toggled off; NO completion event (nothing was
  -- pending at the drain boundary); no cancellation.
  A.assert_eq(rec.count("chat.soft_stop_requested"), 2, "sst2: requested then toggled off")
  A.assert_eq(rec.count("chat.soft_stop_completed"), 0, "sst2: no completion event after toggle-off")
  A.assert_eq(rec.count("response.cancelled"), 0, "sst2: no cancellation")
  A.assert_eq(rec.count("continuation.decided"), 1, "sst2: one decision (continue)")
  local decided
  for _, item in ipairs(rec.items) do
    if item.event == "continuation.decided" then
      decided = item
      break
    end
  end
  A.assert_eq(decided.payload.decision_kind, "continue", "sst2: decision continue")
end

if A.ok then
  print("SOFT_STOP_TOOLS_OK")
else
  error("SOFT_STOP_TOOLS_FAILED count=" .. #A.failures)
end
