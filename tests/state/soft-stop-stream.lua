-- filepath: tests/state/soft-stop-stream.lua
--- Phase-2 W6 fixture: a soft stop requested DURING a streaming response
--- drains the current response (never cancels the provider), persists the
--- result, suppresses any automatic continuation, and parks the AgentLoop at
--- waiting_for_user; a later manual submit proceeds normally.
---
--- Assertions (runtime-fixture-contract state/soft-stop-stream):
---   * soft_stop accepted while busy (injected mid-stream through a scripted
---     provider wrapping the orchestrator callbacks);
---   * the stream completes normally: response.completed exactly once, NO
---     response.cancelled, request terminal completed;
---   * chat.soft_stop_requested (requested=true, source=manual) and
---     chat.soft_stop_completed (reason=soft_stop) each exactly once;
---   * no automatic continuation (one request, one provider call);
---   * session + AgentLoop parked at waiting_for_user;
---   * a fresh manual submit completes normally and does not re-trigger a soft
---     stop (the request flag was consumed at the drain boundary).
---
--- Fixture convention: prints SOFT_STOP_STREAM_OK on success; throws on failure.

local assert_mod = require("tests.state.lib.assert")
local recorder = require("tests.state.lib.recorder")
local events = require("maxa.runtime.events")
local orchestrator = require("maxa.runtime.orchestrator")
local protocol = require("maxa.runtime.protocol")
local normalize = require("maxa.runtime.protocol.normalize")

local A = assert_mod.new()

-- W6 config consumption: a plain orchestrator.new falls back to the documented
-- ORCHESTRATOR_DEFAULTS (headless default-value assertion).
do
  local bus = events.new()
  local plain = orchestrator.new({ provider = protocol.get(protocol.providers.mock), events = bus })
  A.assert_eq(plain.orchestrator_config.tool_concurrency, 1, "cfg: tool_concurrency default 1")
  A.check(plain.orchestrator_config.watchdog.enabled == false, "cfg: watchdog default disabled")
  A.assert_eq(plain.orchestrator_config.watchdog.timeout_ms, 180000, "cfg: watchdog timeout_ms default")
  A.assert_eq(plain.orchestrator_config.watchdog.max_retries, 3, "cfg: watchdog max_retries default")
  A.check(plain.orchestrator_config.context_stop.enabled == false, "cfg: context_stop default disabled")
end

local mock = protocol.get(protocol.providers.mock)
local calls = 0
local soft_called = false
local orch
local scripted = {
  name = "scripted-soft-stop-stream",
  protocol = "mock",
  capabilities = mock.capabilities,
}
function scripted.stream(_, params, callbacks)
  calls = calls + 1
  local orig_on_event = callbacks.on_event
  callbacks.on_event = function(event)
    orig_on_event(event)
    -- Inject the soft stop on the first content delta, i.e. DURING the stream
    -- (the session is busy at this moment; sync drive keeps it deterministic).
    if not soft_called and event and event.type == normalize.events.message_delta then
      soft_called = true
      local ss = orch:soft_stop()
      A.check(ss.accepted == true, "ss-stream: soft_stop accepted mid-stream")
    end
  end
  params = vim.tbl_deep_extend("force", params or {}, { chunks = { "part one ", "part two ", "part three" } })
  return mock.stream(mock, params, callbacks)
end

do
  local bus = events.new()
  orch = orchestrator.new({ provider = scripted, events = bus })
  local rec = recorder.new()
  rec.attach(bus)

  local res = orch:submit("please drain", { provider_params = { chunks = {} } })
  A.assert_eq(res.terminal_state, "completed", "ss-stream: request completed (drained, not cancelled)")
  A.assert_eq(calls, 1, "ss-stream: exactly one provider call (no continuation)")
  A.check(#orch.session.requests == 1, "ss-stream: exactly one request")

  -- Events: soft-stop request + completion exactly once; no cancel.
  A.assert_eq(rec.count("chat.soft_stop_requested"), 1, "ss-stream: soft_stop_requested once")
  local req_item
  for _, item in ipairs(rec.items) do
    if item.event == "chat.soft_stop_requested" then
      req_item = item
      break
    end
  end
  A.check(req_item ~= nil and req_item.payload.requested == true, "ss-stream: requested=true")
  A.assert_eq(req_item.payload.source, "manual", "ss-stream: source manual")
  A.assert_eq(rec.count("chat.soft_stop_completed"), 1, "ss-stream: soft_stop_completed once")
  local done_item
  for _, item in ipairs(rec.items) do
    if item.event == "chat.soft_stop_completed" then
      done_item = item
      break
    end
  end
  A.check(done_item ~= nil, "ss-stream: completion event present")
  A.assert_eq(done_item.payload.reason, "soft_stop", "ss-stream: completion reason soft_stop")
  A.assert_eq(rec.count("response.cancelled"), 0, "ss-stream: no response.cancelled")
  A.assert_eq(rec.count("response.completed"), 1, "ss-stream: response.completed once")

  -- Persisted result + boundaries.
  local stack = orch.messages
  A.assert_eq(stack:len(), 2, "ss-stream: user + assistant messages")
  A.assert_eq(stack:get(2).role, "assistant", "ss-stream: assistant persisted")
  A.assert_eq(stack:get(2).content[1].text, "part one part two part three", "ss-stream: drained text persisted")
  A.assert_eq(orch.session.state, "waiting_for_user", "ss-stream: session waiting_for_user")
  A.assert_eq(orch.session.loop.state, "waiting_for_user", "ss-stream: loop parked")
  A.check(orch._soft_stop_requested == false, "ss-stream: soft-stop flag consumed at drain")

  -- Manual submit after the drain works and does not re-trigger a soft stop.
  local res2 = orch:submit("continue normally", { provider_params = { chunks = {} } })
  A.assert_eq(res2.terminal_state, "completed", "ss-stream: manual submit after soft stop completes")
  A.assert_eq(calls, 2, "ss-stream: second provider call (manual)")
  A.assert_eq(rec.count("chat.soft_stop_requested"), 1, "ss-stream: soft stop not re-requested")
  A.assert_eq(rec.count("chat.soft_stop_completed"), 1, "ss-stream: completion not re-emitted")
end

if A.ok then
  print("SOFT_STOP_STREAM_OK")
else
  error("SOFT_STOP_STREAM_FAILED count=" .. #A.failures)
end
