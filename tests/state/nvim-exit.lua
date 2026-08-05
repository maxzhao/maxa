-- filepath: tests/state/nvim-exit.lua
--- Phase-2 W8 fixture: nvim exit performs BEST-EFFORT cancellation and cleanup
--- (orchestrator:shutdown / host M.shutdown / VimLeavePre hook), closes every
--- closeable owned handle, and failure reporting never creates new work.
---
--- Assertions (runtime-fixture-contract async/nvim-exit):
--- Scenario 1 (stuck provider + pending watchdog retry backoff):
---   * shutdown cancels the pending retry backoff timer (fake clock idle),
---     stops the watchdog, closes the session, returns a report with no
---     failures; the already-terminal request is not re-cancelled;
---   * late provider callbacks after shutdown are rejected; advancing the
---     (cancelled) backoff fires nothing and no new provider call happens;
---   * a second shutdown is idempotent.
--- Scenario 2 (cancel throws):
---   * the failure is captured in the report; shutdown still completes, the
---     session still closes, no events are emitted and no new work is created.
--- Scenario 3 (tool batch in flight):
---   * the executor is cancelled (batch record terminal cancelled), but the
---     exit is QUIET beyond the executor's own terminal bookkeeping: no
---     response.* events, no continuation.decided, no request.submitted, no
---     new provider call; the request record is cancelled by the session close.
--- Scenario 4 (host hook):
---   * host M.shutdown() iterates the live-view registry and returns a report;
---     a second call is a no-op with zero views.
---
--- Fixture convention: prints NVIM_EXIT_OK on success; throws.

local assert_mod = require("tests.state.lib.assert")
local recorder = require("tests.state.lib.recorder")
local fake_clock = require("tests.state.lib.fake_clock")
local events = require("maxa.runtime.events")
local schema = require("maxa.runtime.schema")
local orchestrator = require("maxa.runtime.orchestrator")
local protocol = require("maxa.runtime.protocol")
local normalize = require("maxa.runtime.protocol.normalize")
local host = require("maxa.runtime.host.nvim")

local A = assert_mod.new()

local mock = protocol.get(protocol.providers.mock)
local TIMEOUT_MS = 60000

-- Scenario 1: stuck provider with a pending watchdog retry backoff.
do
  local fake = fake_clock.new()
  local cancel_count = 0
  local callbacks_ref = nil
  local stream_calls = 0
  local scripted = {
    name = "scripted-nvim-exit-stuck",
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
        return false -- stuck: never fires a terminal
      end,
    }
  end

  local bus = events.new()
  local orch = orchestrator.new({
    provider = scripted,
    events = bus,
    clock = fake,
    orchestrator_config = { watchdog = { enabled = true, timeout_ms = TIMEOUT_MS, max_retries = 3 } },
  })
  local rec = recorder.new()
  rec.attach(bus)

  local res = orch:submit("doomed", { async = true, provider_params = {} })
  A.check(res.async == true, "ne1: submit accepted (stuck)")
  A.assert_eq(fake.pending(), 1, "ne1: watchdog observing")

  -- Watchdog fire -> terminal timeout + retry backoff scheduled.
  fake.advance(TIMEOUT_MS)
  A.assert_eq(rec.count("response.failed"), 1, "ne1: watchdog terminal failed once")
  A.assert_eq(cancel_count, 1, "ne1: stuck handle cancelled by the watchdog terminal")
  A.assert_eq(fake.pending(), 1, "ne1: retry backoff pending")
  A.assert_eq(stream_calls, 1, "ne1: no retry yet")

  -- Exit: best-effort shutdown closes everything remaining.
  local report = orch:shutdown()
  A.check(report.closed == true, "ne1: session closed by shutdown")
  A.check(#report.failures == 0, "ne1: no shutdown failures")
  A.check(fake.idle(), "ne1: backoff timer cancelled (fake clock idle)")
  A.assert_eq(cancel_count, 1, "ne1: terminal request not re-cancelled")
  A.check(orch.session:is_closed(), "ne1: session closed")

  -- Late callbacks rejected; the cancelled backoff never fires.
  local before = #rec.names
  callbacks_ref.on_event(normalize.message_delta("post-exit"))
  callbacks_ref.on_done()
  A.assert_eq(#rec.names, before, "ne1: no events from late callbacks")
  fake.advance(100000)
  A.assert_eq(stream_calls, 1, "ne1: cancelled backoff never submits")
  A.assert_eq(#orch.session.requests, 1, "ne1: one request total")

  -- Idempotent second shutdown.
  local report2 = orch:shutdown()
  A.check(report2.closed == true, "ne1: second shutdown still closed")
  A.check(#report2.failures == 0, "ne1: second shutdown no failures")
  A.assert_eq(stream_calls, 1, "ne1: no new provider work")
end

-- Scenario 2: provider cancel throws -> failure reported, no new work.
do
  local bus = events.new()
  local throwing = {
    name = "scripted-nvim-exit-throw",
    protocol = "mock",
    capabilities = mock.capabilities,
  }
  local stream_calls = 0
  function throwing.stream(_, params, callbacks)
    stream_calls = stream_calls + 1
    return {
      active = true,
      cancel = function()
        error("cancel backend unavailable")
      end,
    }
  end

  local orch = orchestrator.new({ provider = throwing, events = bus })
  local rec = recorder.new()
  rec.attach(bus)

  local res = orch:submit("exit with failure", { async = true, provider_params = {} })
  A.check(res.async == true, "ne2: stream in flight")

  local report = orch:shutdown()
  A.check(report.closed == true, "ne2: session closed despite cancel failure")
  A.check(#report.failures == 1, "ne2: failure reported")
  A.check(tostring(report.failures[1].error):find("cancel backend", 1, true) ~= nil, "ne2: failure message preserved")
  A.check(
    rec.count("response.failed") == 0 and rec.count("response.cancelled") == 0,
    "ne2: quiet — no response events"
  )
  A.assert_eq(stream_calls, 1, "ne2: no new work")
  A.check(orch.session.requests[1].terminal ~= nil, "ne2: request record marked terminal (session close)")
  A.assert_eq(orch.session.requests[1].terminal.state, "cancelled", "ne2: request record cancelled")
end

-- Scenario 3: tool batch in flight during exit.
do
  local bus = events.new()
  local handlers = {
    slow = {
      mode = "async",
      run = function(args, ctx, task)
        return task
      end,
      cancel = function() end,
    },
  }
  local provider = {
    name = "scripted-nvim-exit-tools",
    protocol = "mock",
    capabilities = mock.capabilities,
  }
  local stream_calls = 0
  function provider.stream(_, params, callbacks)
    stream_calls = stream_calls + 1
    params = vim.tbl_deep_extend("force", params or {}, {
      chunks = {
        normalize.tool_call_started("c1", "slow"),
        normalize.tool_call_completed("c1", "{}"),
      },
    })
    return mock.stream(mock, params, callbacks)
  end

  local orch = orchestrator.new({ provider = provider, events = bus, tool_handlers = handlers })
  local rec = recorder.new()
  rec.attach(bus)

  local res = orch:submit("exit mid-batch", { provider_params = {} })
  A.check(res.tool_pending == true, "ne3: batch running")

  local report = orch:shutdown()
  A.check(report.closed == true, "ne3: session closed")
  A.check(#report.failures == 0, "ne3: no failures")
  local batch = orch.session.tool_batches[#orch.session.tool_batches]
  A.assert_eq(batch.terminal.state, "cancelled", "ne3: batch record cancelled")
  A.assert_eq(orch.session.requests[1].terminal.state, "cancelled", "ne3: request record cancelled")
  -- Quiet beyond the executor's own terminal bookkeeping: no response events,
  -- no continuation decision, no submit.
  A.assert_eq(rec.count("response.failed"), 0, "ne3: no response.failed")
  A.assert_eq(rec.count("response.cancelled"), 0, "ne3: no response.cancelled")
  A.assert_eq(rec.count("response.completed"), 1, "ne3: response.completed (pre-batch, unchanged)")
  A.assert_eq(rec.count("continuation.decided"), 0, "ne3: no continuation decision at exit")
  A.assert_eq(rec.count("request.submitted"), 1, "ne3: no new request at exit")
  A.assert_eq(stream_calls, 1, "ne3: no new provider call")
  A.check(rec.count("tool_batch.finished") <= 1, "ne3: executor terminal event at most once")
end

-- Scenario 4: host-level exit hook (headless simulation).
do
  local bus = events.new()
  local view = host.new({ events = bus })
  A.check(#host._views >= 1, "ne4: view registered")
  local report = host.shutdown()
  A.check(type(report) == "table" and report.views >= 1, "ne4: host shutdown covers live views")
  A.check(report.failures == nil or #report.failures == 0, "ne4: no host shutdown failures")
  A.check(view.orch.session:is_closed(), "ne4: view orchestrator session closed")
  A.check(view.status == "closed", "ne4: view closed")
  A.check(#host._views == 0, "ne4: closed views leave the registry")
  local report2 = host.shutdown()
  A.check(report2.views == 0, "ne4: second host shutdown no-op")
end

if A.ok then
  print("NVIM_EXIT_OK")
else
  error("NVIM_EXIT_FAILED count=" .. #A.failures)
end
