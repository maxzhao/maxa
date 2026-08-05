-- filepath: tests/state/context-limit-idle.lua
--- Phase-2 W6 fixture: a config-armed context-stop limit reached while the
--- session is IDLE blocks the automatic-continuation submit with a typed
--- rejection (no request, no user turn) and consumes the limit exactly once;
--- a manual submit proceeds normally. Usage unavailable at arm time fails
--- closed (limit not armed, typed arm error, checks never trigger).
---
--- Assertions (runtime-fixture-contract state/context-limit-idle):
---   * fail-closed: no usage_provider -> context_stop NOT armed, arm_error
---     recorded, _context_stop_check() never triggers, automatic submit not
---     context-blocked;
---   * idle at/over the target (string percent "70%" parsed to 0.7):
---     automatic submit rejected (code invalid_argument, cause.context_stop),
---     zero requests, zero user turns;
---   * chat.soft_stop_requested (source=context_stop) exactly once; limit
---     consumed (triggered);
---   * manual submit completes normally; no second trigger.
---
--- Fixture convention: prints CONTEXT_LIMIT_IDLE_OK on success; throws.

local assert_mod = require("tests.state.lib.assert")
local recorder = require("tests.state.lib.recorder")
local events = require("maxa.runtime.events")
local orchestrator = require("maxa.runtime.orchestrator")
local protocol = require("maxa.runtime.protocol")

local A = assert_mod.new()

-- Scenario 1: usage unavailable -> fail-closed (arm fails, checks never fire).
do
  local bus = events.new()
  local orch = orchestrator.new({
    provider = protocol.get(protocol.providers.mock),
    events = bus,
    orchestrator_config = { context_stop = { enabled = true, target = 50 } },
    -- W6.5: a default local-estimate usage provider is installed automatically;
    -- fail-closed semantics are preserved by injecting an unavailable usage
    -- source at construction (usage nil -> arm rejected, checks never fire).
    usage_provider = function()
      return nil
    end,
  })
  A.check(orch._context_stop.enabled == false, "cli: fail-closed (limit not armed without usage)")
  A.check(orch._context_stop.arm_error ~= nil, "cli: typed arm error recorded")
  local rec = recorder.new()
  rec.attach(bus)
  A.check(orch:_context_stop_check() == false, "cli: check never triggers without usage")
  A.assert_eq(rec.count("chat.soft_stop_requested"), 0, "cli: no trigger event")

  -- Automatic submit is NOT context-blocked (fail-closed): it proceeds to the
  -- idle boundary and runs normally.
  local res = orch:submit("", { kind = "automatic", intent_id = "auto:failclosed" })
  A.check(res.rejected ~= true, "cli: automatic submit not blocked (fail-closed)")
  A.assert_eq(res.terminal_state, "completed", "cli: automatic submit completed")
end

-- Scenario 2: idle at/over the target -> automatic submit blocked, manual OK.
do
  local usage = { ratio = 0.8 }
  local bus = events.new()
  local orch = orchestrator.new({
    provider = protocol.get(protocol.providers.mock),
    events = bus,
    orchestrator_config = { context_stop = { enabled = true, target = "70%" } },
    usage_provider = function()
      return { ratio = usage.ratio }
    end,
  })
  local rec = recorder.new()
  rec.attach(bus)

  A.check(orch._context_stop.enabled == true, "cli2: limit armed")
  A.assert_eq(orch._context_stop.target_ratio, 0.7, "cli2: string percent parsed to 0.7")

  -- Idle at/over the target: the automatic continuation submit is blocked.
  local res = orch:submit("", { kind = "automatic", intent_id = "auto:blocked" })
  A.check(res.rejected == true, "cli2: automatic submit rejected")
  A.assert_eq(res.error.code, "invalid_argument", "cli2: typed error code")
  A.check(res.error.cause ~= nil and res.error.cause.context_stop == true, "cli2: error carries context_stop cause")
  A.check(#orch.session.requests == 0, "cli2: no request created")
  A.check(orch.messages == nil or orch.messages:len() == 0, "cli2: no user turn created")

  -- Trigger + one-shot consumption.
  A.assert_eq(rec.count("chat.soft_stop_requested"), 1, "cli2: trigger event once")
  local req_item
  for _, item in ipairs(rec.items) do
    if item.event == "chat.soft_stop_requested" then
      req_item = item
      break
    end
  end
  A.check(req_item.payload.requested == true, "cli2: requested=true")
  A.assert_eq(req_item.payload.source, "context_stop", "cli2: source context_stop")
  A.check(orch._context_stop.triggered == true, "cli2: limit consumed (one-shot)")

  -- Manual submit proceeds normally; the consumed limit does not re-trigger.
  local res2 = orch:submit("hello", { provider_params = { chunks = { "hi" } } })
  A.assert_eq(res2.terminal_state, "completed", "cli2: manual submit completes")
  A.assert_eq(rec.count("chat.soft_stop_requested"), 1, "cli2: no second trigger")
end

if A.ok then
  print("CONTEXT_LIMIT_IDLE_OK")
else
  error("CONTEXT_LIMIT_IDLE_FAILED count=" .. #A.failures)
end
