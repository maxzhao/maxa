-- filepath: tests/state/watchdog-tool-excluded.lua
--- Phase-2 W7 fixture: the watchdog does NOT classify local tool execution as a
--- provider stall (spec §Progress and recovery). While the ToolBatch executor
--- runs, the observation timer is paused (fake clock: advancing far beyond the
--- timeout triggers nothing). After the batch terminal the continuation starts
--- a NEW request whose fresh observation window detects the stall (tool result
--- written but the provider never continues) and retries THAT request.
---
--- Assertions (runtime-fixture-contract state/watchdog-tool-excluded):
---   * submit -> tool batch (async handler) -> watchdog paused, no timers;
---   * advance(2x timeout) -> NO watchdog.retry / response.failed (tool phase
---     excluded, request NOT terminated);
---   * task.complete -> batch completed -> continuation.decided (continue) ->
---     automatic submit (stuck) -> watchdog observing the continuation;
---   * advance(timeout) -> watchdog.retry (1/3, no_message) + response.failed +
---     decision retry; the retry_of chain targets the CONTINUATION request;
---   * backoff -> retry submits and completes (timer removed).
---
--- Fixture convention: prints WATCHDOG_TOOL_EXCLUDED_OK on success; throws.

local assert_mod = require("tests.state.lib.assert")
local recorder = require("tests.state.lib.recorder")
local fake_clock = require("tests.state.lib.fake_clock")
local stuck = require("tests.state.lib.stuck")
local events = require("maxa.runtime.events")
local orchestrator = require("maxa.runtime.orchestrator")

local A = assert_mod.new()

local TIMEOUT_MS = 60000

do
  local fake = fake_clock.new()
  local bus = events.new()
  local rec = recorder.new()
  rec.attach(bus)
  -- Call 1 -> tool call (executor phase); call 2 -> stuck (continuation);
  -- call 3 -> recovery (cleanup retry).
  local provider, calls = stuck.make({ "tool", "stuck", "tool continuation recovered" })
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
  local orch = orchestrator.new({
    provider = provider,
    events = bus,
    clock = fake,
    tool_handlers = handlers,
    orchestrator_config = { watchdog = { enabled = true, timeout_ms = TIMEOUT_MS, max_retries = 3 } },
  })

  -- 1) Tool turn: the executor is running -> watchdog paused (no timers).
  local res = orch:submit("tool turn", { provider_params = {} })
  A.check(res.tool_pending == true, "wte: tool batch pending")
  A.check(orch._active_executor ~= nil and not orch._active_executor:is_terminal(), "wte: executor running")
  A.check(next(orch._watchdog.pauses) ~= nil, "wte: watchdog paused for tool execution")
  A.check(fake.idle(), "wte: no observation timer during tool execution")

  -- 2) Tool execution far beyond the timeout is NOT a stall.
  fake.advance(TIMEOUT_MS * 2)
  A.assert_eq(rec.count("watchdog.retry"), 0, "wte: no retry during tool execution")
  A.assert_eq(rec.count("response.failed"), 0, "wte: no terminal failure during tool execution")
  A.check(orch.session:is_busy(), "wte: request still active (not terminated)")

  -- 3) Tool result written -> batch barrier -> continue -> automatic submit.
  task_ref.complete({ content = "tool result" })
  A.check(orch._active_executor == nil, "wte: executor released at barrier")
  A.assert_eq(rec.count("continuation.decided"), 1, "wte: one decision")
  local dec
  for _, item in ipairs(rec.items) do
    if item.event == "continuation.decided" then
      dec = item
    end
  end
  A.assert_eq(dec.payload.decision_kind, "continue", "wte: continuation after batch")
  A.assert_eq(#orch.session.requests, 2, "wte: manual + automatic continuation")
  local req2 = orch.session.requests[2]
  A.assert_eq(req2.intent, "automatic", "wte: continuation intent automatic")
  A.check(orch.session:is_busy(), "wte: continuation request stuck -> busy")
  A.assert_eq(fake.pending(), 1, "wte: watchdog observes the continuation (fresh window)")

  -- 4) The continuation produces nothing within the timeout -> watchdog fires.
  fake.advance(TIMEOUT_MS)
  A.assert_eq(rec.count("watchdog.retry"), 1, "wte: retry after continuation stall")
  local wr
  for _, item in ipairs(rec.items) do
    if item.event == "watchdog.retry" then
      wr = item
      break
    end
  end
  A.assert_eq(wr.payload.retry_count, 1, "wte: retry_count 1")
  A.assert_eq(wr.payload.reason, "no_message", "wte: no_message on the continuation")
  A.assert_eq(wr.payload.request_id, req2.id, "wte: fire targets the continuation request")
  A.assert_eq(rec.count("response.failed"), 1, "wte: one watchdog failure")
  A.assert_eq(rec.count("continuation.decided"), 2, "wte: second decision")
  local dec2
  for _, item in ipairs(rec.items) do
    if item.event == "continuation.decided" then
      dec2 = item
    end
  end
  A.assert_eq(dec2.payload.decision_kind, "retry", "wte: decision retry")
  A.assert_eq(fake.pending(), 1, "wte: backoff pending")

  -- 5) Backoff -> retry (targets the continuation request) -> recovery.
  fake.advance(orch._watchdog:backoff_ms())
  A.assert_eq(calls(), 3, "wte: retry called the provider")
  A.assert_eq(#orch.session.requests, 3, "wte: three requests")
  local req3 = orch.session.requests[3]
  A.assert_eq(req3.intent, "retry", "wte: retry intent")
  A.assert_eq(req3.retry_of, req2.id, "wte: retry chained to the continuation request")
  A.assert_eq(req3.terminal.state, "completed", "wte: retried request completed")
  A.assert_eq(orch.session.state, "waiting_for_user", "wte: session waiting_for_user")
  A.check(fake.idle(), "wte: timer removed at the end")
end

if A.ok then
  print("WATCHDOG_TOOL_EXCLUDED_OK")
else
  error("WATCHDOG_TOOL_EXCLUDED_FAILED count=" .. #A.failures)
end
