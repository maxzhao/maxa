-- filepath: tests/state/double-cleanup.lua
--- Phase-2 W8 fixture: repeated cancel / close / shutdown / teardown is
--- idempotent — the second call is a no-op that never errors, never emits and
--- never mutates (runtime-fixture-contract async/double-cleanup).
---
--- Coverage:
---   * orchestrator:cancel() twice (provider in flight) — one terminal, one
---     provider cancel invocation, second call false;
---   * orchestrator:close() twice — first closes, second false, no events;
---   * orchestrator:shutdown() twice — no failures, session stays closed;
---   * session:close() twice + view close/detach twice;
---   * executor:cancel() twice + late task.complete() rejected;
---   * watchdog stop/reset twice + retry-backoff cancellation twice (pending
---     retry never fires after close);
---   * host View:close() twice — idempotent, no error.
---
--- Fixture convention: prints DOUBLE_CLEANUP_OK on success; throws.

local assert_mod = require("tests.state.lib.assert")
local recorder = require("tests.state.lib.recorder")
local fake_clock = require("tests.state.lib.fake_clock")
local events = require("maxa.runtime.events")
local schema = require("maxa.runtime.schema")
local session = require("maxa.runtime.session")
local orchestrator = require("maxa.runtime.orchestrator")
local tools = require("maxa.runtime.tools")
local protocol = require("maxa.runtime.protocol")
local normalize = require("maxa.runtime.protocol.normalize")
local host = require("maxa.runtime.host.nvim")

local A = assert_mod.new()

local mock = protocol.get(protocol.providers.mock)

-- 1) cancel twice (provider stream in flight, mock-like cancel).
do
  local cancel_count = 0
  local provider = {
    name = "scripted-double-cancel",
    protocol = "mock",
    capabilities = mock.capabilities,
  }
  function provider.stream(_, params, callbacks)
    return {
      active = true,
      cancel = function()
        cancel_count = cancel_count + 1
        if cancel_count == 1 then
          callbacks.on_error(schema.new_error(schema.ERROR.CANCELLED, "cancelled", nil, true))
          return true
        end
        return false
      end,
    }
  end

  local bus = events.new()
  local orch = orchestrator.new({ provider = provider, events = bus })
  local rec = recorder.new()
  rec.attach(bus)

  local res = orch:submit("cancel twice", { async = true, provider_params = {} })
  A.check(res.async == true, "dc1: in flight")
  A.check(orch:cancel("first") == true, "dc1: first cancel performed")
  A.assert_eq(cancel_count, 1, "dc1: one provider cancel")
  A.assert_eq(rec.count("response.cancelled"), 1, "dc1: one terminal")
  A.check(orch:cancel("second") == false, "dc1: second cancel no-op")
  A.assert_eq(cancel_count, 1, "dc1: provider cancel still once")
  A.assert_eq(rec.count("response.cancelled"), 1, "dc1: still one terminal")
end

-- 2) close twice + shutdown twice on the same orchestrator.
do
  local bus = events.new()
  local orch = orchestrator.new({ provider = mock, events = bus })
  local rec = recorder.new()
  rec.attach(bus)
  local res = orch:submit("close twice", { provider_params = { chunks = { "ok" } } })
  A.assert_eq(res.terminal_state, "completed", "dc2: completed before close")

  A.check(orch:close() == true, "dc2: first close performed")
  A.check(orch.session:is_closed(), "dc2: session closed")
  local names_after_close = #rec.names
  A.check(orch:close() == false, "dc2: second close no-op")
  A.assert_eq(#rec.names, names_after_close, "dc2: no events from second close")

  local r1 = orch:shutdown()
  A.check(r1.closed == true, "dc2: shutdown after close reports closed")
  A.check(#r1.failures == 0, "dc2: no shutdown failures")
  local r2 = orch:shutdown()
  A.check(r2.closed == true and #r2.failures == 0, "dc2: second shutdown idempotent")
  A.assert_eq(#rec.names, names_after_close, "dc2: shutdown emitted nothing")
end

-- 3) session close twice + view close/detach twice.
do
  local bus = events.new()
  local s = session.new({ events = bus })
  local v = s:new_view({ view_id = "dc-view", bufnr = 1 })
  A.check(s:close_view(v) == true, "dc3: view close once")
  A.check(s:close_view(v) == false, "dc3: view close twice no-op")
  A.check(s:detach_view(v) == false, "dc3: detach on closed view no-op")
  A.check(s:close() == true, "dc3: session close once")
  A.check(s:close() == false, "dc3: session close twice no-op")
  A.check(s:stop("again") == false, "dc3: stop on closed session no-op")
end

-- 4) executor cancel twice + late complete.
do
  local bus = events.new()
  local s = session.new({ events = bus })
  local req = s:start_request({ intent = "manual" })
  local batch = s:new_tool_batch({
    calls = { { call_id = "c1", name = "slow", arguments = "{}", ordinal = 1 } },
  })
  local conv = require("maxa.runtime.conversation")
  local stack = conv.new_stack()
  local task_ref = nil
  local exec = tools.new_executor({
    session = s,
    batch = batch,
    conversation = conv,
    stack = stack,
    handlers = {
      slow = {
        mode = "async",
        run = function(args, ctx, task)
          task_ref = task
          return task
        end,
      },
    },
    events = bus,
    request = req,
  })
  exec:run_all()
  A.check(batch.state == "running", "dc4: batch running")
  A.check(exec:cancel("first") == true, "dc4: first executor cancel")
  A.assert_eq(batch.terminal.state, "cancelled", "dc4: batch cancelled")
  A.check(exec:cancel("second") == false, "dc4: second executor cancel no-op")
  A.check(task_ref.complete("late") == false, "dc4: late complete rejected")
  A.assert_eq(batch.terminal.state, "cancelled", "dc4: stays cancelled")
end

-- 5) watchdog + retry backoff double-cleanup through close.
do
  local fake = fake_clock.new()
  local provider, calls = require("tests.state.lib.stuck").make({ "stuck", "stuck", "ok" })
  local bus = events.new()
  local orch = orchestrator.new({
    provider = provider,
    events = bus,
    clock = fake,
    orchestrator_config = { watchdog = { enabled = true, timeout_ms = 60000, max_retries = 2 } },
  })
  local wd = orch._watchdog

  local res = orch:submit("stall", { async = true, provider_params = {} })
  A.check(res.async == true, "dc5: stuck in flight")

  -- Watchdog fire -> terminal timeout + retry backoff pending (max_retries 2,
  -- first fire reserves retry 1 -> backoff scheduled).
  fake.advance(60000)
  A.assert_eq(calls(), 1, "dc5: watchdog fired, no retry yet")
  A.check(orch._retry_backoff ~= nil, "dc5: retry backoff pending")
  A.assert_eq(fake.pending(), 1, "dc5: one timer (backoff)")

  -- Double-cleanup each owned timer/observation surface.
  wd:stop()
  wd:stop()
  A.check(wd.active == false, "dc5: watchdog stop idempotent")
  wd:reset()
  wd:reset()
  A.check(wd.retry_count == 0, "dc5: watchdog reset idempotent")
  orch:_cancel_retry_backoff()
  orch:_cancel_retry_backoff()
  A.check(orch._retry_backoff == nil, "dc5: backoff cancelled twice")
  A.check(fake.idle(), "dc5: clock idle after double cleanup")

  -- The cancelled backoff never fires a retry submit.
  fake.advance(100000)
  A.assert_eq(calls(), 1, "dc5: cancelled backoff never fired")

  A.check(orch:close() == true, "dc5: close after cleanup")
  A.check(orch:close() == false, "dc5: second close no-op")
  A.check(fake.idle(), "dc5: no timers remain after close")
end

-- 6) host View:close twice.
do
  local bus = events.new()
  local view = host.new({ events = bus })
  A.check(view:close() == true, "dc6: first view close")
  A.check(view:close() == false, "dc6: second view close no-op")
  A.check(view.status == "closed", "dc6: view closed")
end

if A.ok then
  print("DOUBLE_CLEANUP_OK")
else
  error("DOUBLE_CLEANUP_FAILED count=" .. #A.failures)
end
