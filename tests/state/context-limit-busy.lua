-- filepath: tests/state/context-limit-busy.lua
--- Phase-2 W6 fixture: a config-armed context-stop limit reached while the
--- session is BUSY triggers a ONE-SHOT soft stop at the drain boundary: the
--- current tool batch drains (results persisted), the automatic continuation
--- is suppressed (decision wait(context_stop)), and the armed limit is
--- consumed exactly once (a later drain at/over the target does NOT trigger
--- again).
---
--- Assertions (runtime-fixture-contract state/context-limit-busy):
---   * context_stop armed from orchestrator_config (absolute percent 50 ->
---     0.5 ratio; injectable usage_provider);
---   * busy reach -> chat.soft_stop_requested (source=context_stop) exactly
---     once + chat.soft_stop_completed (reason=context_stop) once;
---   * batch drains to completed (never cancelled); no continuation;
---   * decision wait(context_stop); session + loop parked;
---   * one-shot: a second batch drain at/over the target continues normally
---     (decision continue) without re-triggering.
---
--- Fixture convention: prints CONTEXT_LIMIT_BUSY_OK on success; throws.

local assert_mod = require("tests.state.lib.assert")
local recorder = require("tests.state.lib.recorder")
local events = require("maxa.runtime.events")
local orchestrator = require("maxa.runtime.orchestrator")
local protocol = require("maxa.runtime.protocol")
local normalize = require("maxa.runtime.protocol.normalize")

local A = assert_mod.new()

local mock = protocol.get(protocol.providers.mock)

-- Scripted provider: call 1 -> tool call; call 2 -> tool call; call 3 -> text.
---@param counter table { n = integer }
---@return table provider
local function make_scripted(counter)
  local scripted = {
    name = "scripted-context-limit-busy",
    protocol = "mock",
    capabilities = mock.capabilities,
  }
  function scripted.stream(_, params, callbacks)
    counter.n = counter.n + 1
    if counter.n <= 2 then
      params = vim.tbl_deep_extend("force", params or {}, {
        chunks = {
          normalize.tool_call_started(("c%d"):format(counter.n), "slow"),
          normalize.tool_call_completed(("c%d"):format(counter.n), "{}"),
        },
      })
    else
      params = vim.tbl_deep_extend("force", params or {}, { chunks = { "final text" } })
    end
    return mock.stream(mock, params, callbacks)
  end
  return scripted
end

do
  local usage = { ratio = 0.3 } -- below the 50% target at arm time
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
  local orch = orchestrator.new({
    provider = make_scripted(counter),
    events = bus,
    tool_handlers = handlers,
    orchestrator_config = { context_stop = { enabled = true, target = 50 } },
    usage_provider = function()
      return { ratio = usage.ratio }
    end,
  })
  local rec = recorder.new()
  rec.attach(bus)

  A.check(orch._context_stop.enabled == true, "clb: context-stop armed")
  A.assert_eq(orch._context_stop.target_ratio, 0.5, "clb: absolute target parsed to 0.5")

  -- Round 1: reach the target while the batch is running.
  local res = orch:submit("tool round", { provider_params = { chunks = {} } })
  A.check(res.tool_pending == true, "clb: submit reports tool_pending")
  usage.ratio = 0.6 -- at/over target during the busy drain
  task_ref.complete({ content = "echo:z" })

  local batch = orch.session.tool_batches[1]
  A.assert_eq(batch.terminal.state, "completed", "clb: batch drained (completed, not cancelled)")
  A.check(batch.calls[1].result ~= nil and batch.calls[1].result.status == "success", "clb: result persisted")
  A.assert_eq(counter.n, 1, "clb: no continuation after context stop")
  A.check(#orch.session.requests == 1, "clb: exactly one request")

  -- Trigger events: soft-stop requested (context_stop source) + completed.
  A.assert_eq(rec.count("chat.soft_stop_requested"), 1, "clb: soft_stop_requested once")
  local req_item
  for _, item in ipairs(rec.items) do
    if item.event == "chat.soft_stop_requested" then
      req_item = item
      break
    end
  end
  A.check(req_item.payload.requested == true, "clb: requested=true")
  A.assert_eq(req_item.payload.source, "context_stop", "clb: source context_stop")
  A.assert_eq(rec.count("chat.soft_stop_completed"), 1, "clb: soft_stop_completed once")
  local done_item
  for _, item in ipairs(rec.items) do
    if item.event == "chat.soft_stop_completed" then
      done_item = item
      break
    end
  end
  A.assert_eq(done_item.payload.reason, "context_stop", "clb: completion reason context_stop")
  A.assert_eq(rec.count("response.cancelled"), 0, "clb: no cancellation")

  -- Decision boundary: wait(context_stop); loop parked.
  local decided
  for _, item in ipairs(rec.items) do
    if item.event == "continuation.decided" then
      decided = item
      break
    end
  end
  A.check(decided ~= nil, "clb: continuation.decided emitted")
  A.assert_eq(decided.payload.decision_kind, "wait", "clb: decision wait")
  A.assert_eq(decided.payload.decision_reason, "context_stop", "clb: decision reason context_stop")
  A.assert_eq(orch.session.state, "waiting_for_user", "clb: session waiting_for_user")
  A.assert_eq(orch.session.loop.state, "waiting_for_user", "clb: loop parked")
  A.check(orch._context_stop.triggered == true, "clb: limit consumed (one-shot)")

  -- Round 2: usage stays at/over the target, but the limit is consumed: the
  -- batch continues normally (decision continue) without re-triggering.
  local res2 = orch:submit("tool round two", { provider_params = { chunks = {} } })
  A.check(res2.tool_pending == true, "clb: round 2 tool_pending")
  task_ref.complete({ content = "echo:w" })
  A.assert_eq(orch.session.tool_batches[2].terminal.state, "completed", "clb: round 2 batch completed")
  A.assert_eq(counter.n, 3, "clb: continuation ran (one automatic request)")
  A.check(#orch.session.requests == 3, "clb: three requests (manual, manual, automatic)")
  A.assert_eq(orch.session.requests[3].intent, "automatic", "clb: round 2 continuation automatic")
  A.assert_eq(rec.count("chat.soft_stop_requested"), 1, "clb: one-shot — no second trigger")
  A.assert_eq(rec.count("chat.soft_stop_completed"), 1, "clb: one-shot — no second completion")
  A.assert_eq(rec.count("continuation.decided"), 2, "clb: two decisions (wait + continue)")
end

if A.ok then
  print("CONTEXT_LIMIT_BUSY_OK")
else
  error("CONTEXT_LIMIT_BUSY_FAILED count=" .. #A.failures)
end
