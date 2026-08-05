-- filepath: tests/state/hard-cancel-provider.lua
--- Phase-2 W8 fixture: hard cancel of an in-flight provider stream owns the
--- terminal exactly once.
---
--- Assertions (runtime-fixture-contract async/hard-cancel-provider):
---   * provider handle.cancel is invoked EXACTLY once (the orchestrator calls
---     it once; a second cancel() is an idempotent no-op);
---   * the cancel-driven terminal (on_error CANCELLED) fires once: one
---     response.cancelled, request terminal cancelled, session
---     waiting_for_user;
---   * LATE chunks after the cancel are rejected by request identity +
---     terminal guard: no message.delta event, no buffer mutation, no second
---     terminal (on_done / on_error are both no-ops);
---   * event order is deterministic: request.submitted -> response.cancelled
---     (no response.completed / response.failed / message.delta anywhere);
---   * resource cleanup: watchdog disabled (no timers), no continuation
---     (one request, one provider call).
---
--- Fixture convention: prints HARD_CANCEL_PROVIDER_OK on success; throws.

local assert_mod = require("tests.state.lib.assert")
local recorder = require("tests.state.lib.recorder")
local events = require("maxa.runtime.events")
local schema = require("maxa.runtime.schema")
local orchestrator = require("maxa.runtime.orchestrator")
local protocol = require("maxa.runtime.protocol")
local normalize = require("maxa.runtime.protocol.normalize")

local A = assert_mod.new()

local mock = protocol.get(protocol.providers.mock)

do
  -- Scripted provider: stream returns a live handle whose cancel mimics the
  -- mock adapter (first cancel fires on_error CANCELLED synchronously and
  -- returns true; later cancels return false) and records every invocation.
  local cancel_count = 0
  local callbacks_ref = nil
  local stream_calls = 0
  local scripted = {
    name = "scripted-hard-cancel-provider",
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
          callbacks.on_error(schema.new_error(schema.ERROR.CANCELLED, "stream cancelled by caller", nil, true))
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

  -- Async submit: the stream is live, no terminal yet.
  local res = orch:submit("cancel me", { async = true, provider_params = {} })
  A.check(res.async == true, "hcp: async submit accepted")
  A.check(res.handle ~= nil, "hcp: live handle returned")
  A.check(orch:is_busy(), "hcp: session busy while streaming")
  A.assert_eq(rec.count("request.submitted"), 1, "hcp: one request.submitted")
  A.assert_eq(rec.count("response.cancelled"), 0, "hcp: no terminal before cancel")
  A.assert_eq(stream_calls, 1, "hcp: one provider call")
  A.assert_eq(cancel_count, 0, "hcp: no cancel yet")

  -- Hard cancel: provider cancel invoked once -> terminal cancelled once.
  local cancelled = orch:cancel("hard provider cancel")
  A.check(cancelled == true, "hcp: cancel performed")
  A.assert_eq(cancel_count, 1, "hcp: provider cancel invoked exactly once")
  A.assert_eq(rec.count("response.cancelled"), 1, "hcp: response.cancelled once")
  A.assert_eq(rec.count("response.completed"), 0, "hcp: no response.completed")
  A.assert_eq(rec.count("response.failed"), 0, "hcp: no response.failed")
  A.assert_eq(orch.session.requests[1].terminal.state, "cancelled", "hcp: request terminal cancelled")
  A.assert_eq(orch.session.state, "waiting_for_user", "hcp: session waiting_for_user")
  A.check(orch:is_busy() == false, "hcp: session not busy after cancel")

  -- Late chunks are rejected (request identity + terminal guard): no events,
  -- no buffer mutation, no second terminal.
  local before = rec.count("message.delta")
  callbacks_ref.on_event(normalize.message_delta("late text"))
  A.assert_eq(rec.count("message.delta"), before, "hcp: late chunk rejected (no event)")
  A.assert_eq(orch._current.buff, "", "hcp: no buffer mutation from late chunk")
  callbacks_ref.on_event(normalize.message_delta("more late"))
  A.assert_eq(rec.count("message.delta"), before, "hcp: second late chunk rejected")
  callbacks_ref.on_done()
  A.assert_eq(rec.count("response.completed"), 0, "hcp: late on_done cannot complete")
  callbacks_ref.on_error(schema.new_error(schema.ERROR.INTERNAL, "late failure", nil, true))
  A.assert_eq(rec.count("response.failed"), 0, "hcp: late on_error cannot fail")
  A.assert_eq(rec.count("response.cancelled"), 1, "hcp: terminal effect exactly once")
  A.assert_eq(orch.session.requests[1].terminal.state, "cancelled", "hcp: request stays cancelled")

  -- Event order: the only recorded request-scoped events are
  -- request.submitted -> response.cancelled (skip session.created).
  local order = {}
  for _, item in ipairs(rec.items) do
    if item.event ~= "session.created" then
      order[#order + 1] = item.event
    end
  end
  A.assert_eq(table.concat(order, ","), "request.submitted,response.cancelled", "hcp: deterministic event order")

  -- Idempotent second cancel: no provider call, no new terminal.
  local again = orch:cancel("second cancel")
  A.check(again == false, "hcp: second cancel is a no-op")
  A.assert_eq(cancel_count, 1, "hcp: provider cancel still once")
  A.assert_eq(rec.count("response.cancelled"), 1, "hcp: still one terminal")
  A.assert_eq(stream_calls, 1, "hcp: no continuation")
  A.assert_eq(#orch.session.requests, 1, "hcp: one request total")
end

if A.ok then
  print("HARD_CANCEL_PROVIDER_OK")
else
  error("HARD_CANCEL_PROVIDER_FAILED count=" .. #A.failures)
end
