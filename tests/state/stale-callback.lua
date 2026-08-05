-- filepath: tests/state/stale-callback.lua
--- Phase-2 W3 fixture: stale orchestrator callbacks (on_event/on_done/on_error)
--- are rejected unless BOTH the request id AND the request generation match the
--- current _current record (upgraded is_owned). A foreign request id and a
--- same-id/stale-generation record are both rejected without mutation; a
--- matching (id, generation) callback still completes the request.
---
--- The fixture fabricates _current directly (simulating a superseded request)
--- and drives the captured provider callbacks manually.
---
--- Fixture convention: prints STALE_CALLBACK_OK on success; throws on failure.

local assert_mod = require("tests.state.lib.assert")
local recorder = require("tests.state.lib.recorder")
local events = require("maxa.runtime.events")
local orchestrator = require("maxa.runtime.orchestrator")
local normalize = require("maxa.runtime.protocol.normalize")

local A = assert_mod.new()

-- Provider that captures the callback table and never fires a terminal.
local function capturing_provider()
  local captured = {}
  return {
    captured = captured,
    name = "capture",
    protocol = "capture",
    capabilities = { vision = false, tools = false, reasoning = false },
    stream = function(_, _, callbacks)
      captured[#captured + 1] = callbacks
      return {
        active = true,
        cancel = function()
          return false
        end,
      }
    end,
  }
end

do
  local bus = events.new()
  local cp = capturing_provider()
  local orch = orchestrator.new({ provider = cp, events = bus })
  local rec = recorder.new()
  rec.attach(bus)

  local res = orch:submit("hello", { provider_params = { chunks = { "x" } } })
  local reqA = res.request
  A.check(reqA ~= nil, "stale: request created")
  A.check(orch.session:is_busy(), "stale: session busy (stalled provider)")
  A.check(#cp.captured == 1, "stale: one callback captured")
  local cb = cp.captured[1]
  local real_current = orch._current

  -- 1) Foreign request id: _current belongs to a different (superseding) request.
  orch._current = { request = { id = "req-superseded", generation = 2 }, terminal = false }
  cb.on_event({ type = normalize.events.message_delta, delta = "stale" })
  cb.on_done()
  A.assert_eq(rec.count("message.delta"), 0, "stale: no delta emitted for foreign request")
  A.assert_eq(rec.count("response.completed"), 0, "stale: no terminal for foreign request")
  A.check(reqA.terminal == nil, "stale: foreign callback did not finish request A")
  A.check(orch.session:is_busy(), "stale: session untouched")

  -- 2) Same request id, stale generation: the upgraded ownership check (id AND
  --    generation) rejects the callback before any mutation.
  orch._current = { request = { id = reqA.id, generation = reqA.generation + 1 }, terminal = false }
  cb.on_event({ type = normalize.events.message_delta, delta = "stale2" })
  A.assert_eq(rec.count("message.delta"), 0, "stale: generation mismatch blocks delta")
  cb.on_done()
  A.assert_eq(rec.count("response.completed"), 0, "stale: generation mismatch blocks terminal")
  A.check(reqA.terminal == nil, "stale: request A not finished by stale generation callback")
  A.check(orch.session:is_busy(), "stale: session stays busy")

  -- 3) Control: a matching (id, generation) callback still completes the request.
  orch._current = real_current
  cb.on_done()
  A.assert_eq(rec.count("response.completed"), 1, "stale: matching callback completes")
  A.check(reqA.terminal ~= nil and reqA.terminal.state == "completed", "stale: request A completed")
  A.check(orch.session:is_idle(), "stale: session returned to idle")
end

if A.ok then
  print("STALE_CALLBACK_OK")
else
  error("STALE_CALLBACK_FAILED count=" .. #A.failures)
end
