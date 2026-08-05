-- filepath: tests/state/restore-agent-loop.lua
--- Phase-2 W5 fixture: restore-agent-loop from an in-memory snapshot
--- (Session:snapshot + messages to_table):
---   * loop minimal state (enabled/state/iteration/decision_key/decisions)
---     rebuilt exactly from the snapshot;
---   * orphan assistant tool_call parts (no paired tool result) repaired with a
---     synthetic cancelled result carrying provenance "restore_repair",
---     injected immediately after the owning assistant message, idempotent;
---   * durable-key dedup: replaying the SAME continuation decision point after
---     the restore (same generation/request/batch/kind, reconstructed from the
---     restored decisions) is rejected with the existing record reference — no
---     duplicate continuation submit, no duplicate events;
---   * no duplicate manual user trace (restore adds none; a later manual submit
---     adds exactly one).
---
--- Note: Session:restore rebuilds identity/loop/views only; request/tool-batch
--- audit lists are append-only by design (W3; full audit restore is a later
--- wave), so the dedup replay is built from the restored durable decisions.
---
--- Fixture convention: prints RESTORE_AGENT_LOOP_OK on success; throws.

local assert_mod = require("tests.state.lib.assert")
local recorder = require("tests.state.lib.recorder")
local events = require("maxa.runtime.events")
local orchestrator = require("maxa.runtime.orchestrator")
local protocol = require("maxa.runtime.protocol")
local normalize = require("maxa.runtime.protocol.normalize")
local conversation = require("maxa.runtime.conversation")

local A = assert_mod.new()
local mock = protocol.get(protocol.providers.mock)

-- Scripted provider: call 1 -> tool_call(echo c1); call 2+ -> plain text.
local function scripted_provider()
  local calls = 0
  local prov = {
    name = "scripted-restore",
    protocol = "mock",
    capabilities = mock.capabilities,
  }
  function prov.stream(_, params, callbacks)
    calls = calls + 1
    local chunks
    if calls == 1 then
      chunks = {
        normalize.tool_call_started("c1", "echo"),
        normalize.tool_call_completed("c1", '{"path":"x"}'),
      }
    else
      chunks = { "restored reply " .. calls }
    end
    params = vim.tbl_deep_extend("force", params or {}, { chunks = chunks })
    return mock.stream(mock, params, callbacks)
  end
  function prov.call_count()
    return calls
  end
  return prov
end

-- Text-only provider (used after the restore: the restore request and later
-- manual submits must not create tool batches).
local function text_provider()
  local calls = 0
  local prov = {
    name = "text-restore",
    protocol = "mock",
    capabilities = mock.capabilities,
  }
  function prov.stream(_, params, callbacks)
    calls = calls + 1
    params = vim.tbl_deep_extend("force", params or {}, { chunks = { "plain reply " .. calls } })
    return mock.stream(mock, params, callbacks)
  end
  function prov.call_count()
    return calls
  end
  return prov
end

local handlers = {
  echo = {
    mode = "sync",
    run = function(args)
      return "echo:" .. tostring(args and args.path or "?")
    end,
  },
}

-------------------------------------------------------------------------------
-- Build the source session: manual tool chain (batch + one continuation) then
-- a crashed/incomplete assistant tool_call appended by hand (orphan).
-------------------------------------------------------------------------------
local prov1 = scripted_provider()
local bus1 = events.new()
local orch1 = orchestrator.new({ provider = prov1, events = bus1, tool_handlers = handlers })
local res1 = orch1:submit("start", { provider_params = { chunks = {} } })
A.assert_eq(res1.terminal_state, "completed", "src: chain completed")
A.assert_eq(prov1.call_count(), 2, "src: one continuation happened")
A.assert_eq(orch1.session.loop.iteration, 1, "src: loop iteration 1")
A.assert_eq(orch1.session.loop.state, "waiting_for_user", "src: loop parked after text completion")
local snapshot_decisions = {}
for k in pairs(orch1.session.loop.decisions) do
  snapshot_decisions[k] = true
end
A.check(next(snapshot_decisions) ~= nil, "src: at least one durable decision recorded")

-- Append an orphan assistant tool_call (interrupted chain; no paired result).
orch1.messages:add_message(
  { role = "assistant", content = { conversation.tool_call_part("orphan1", "echo", "{}") } },
  { turn_id = "turn-orphan" }
)
local snapshot = { session = orch1.session:snapshot(), messages = orch1.messages:to_table() }
local snapshot_msg_count = #snapshot.messages

-------------------------------------------------------------------------------
-- Restore into a fresh orchestrator (text-only provider: the restore request
-- must not create a tool batch or a new continuation).
-------------------------------------------------------------------------------
local prov2 = text_provider()
local bus2 = events.new()
local orch2 = orchestrator.new({ provider = prov2, events = bus2, tool_handlers = handlers })
local rec2 = recorder.new()
rec2.attach(bus2)
local rres = orch2:restore_agent_loop(snapshot)
A.check(rres ~= nil and rres.rejected ~= true, "restore: restore accepted")

local st2 = orch2.session
-- Loop minimal state matches the snapshot exactly (the restore request itself
-- is text-only: it parks the loop but touches neither iteration nor decisions
-- nor decision_key).
A.check(st2.loop.enabled == true, "restore: loop enabled")
A.assert_eq(st2.loop.state, "waiting_for_user", "restore: loop state restored (parked)")
A.assert_eq(st2.loop.iteration, 1, "restore: loop iteration restored")
A.assert_eq(st2.loop.decision_key, orch1.session.loop.decision_key, "restore: decision_key restored")
for k in pairs(snapshot_decisions) do
  A.check(st2.loop.decisions[k] ~= nil, "restore: durable decision " .. k .. " present")
end
-- The restore request is the ONLY new request; no duplicate continuation.
A.assert_eq(prov2.call_count(), 1, "restore: exactly the restore request ran")
A.assert_eq(#st2.requests, 1, "restore: audit lists are append-only; only the restore request")

-- Orphan repair: exactly one synthetic tool result injected for orphan1,
-- cancelled status, provenance restore_repair, positioned after the owning
-- assistant message.
local repaired = 0
local orphan_idx = nil
local i = 0
for msg in orch2.messages:iter() do
  i = i + 1
  if msg.role == "assistant" then
    for _, part in ipairs(msg.content or {}) do
      if part.type == "tool_call" and part.call_id == "orphan1" then
        orphan_idx = i
      end
    end
  elseif msg.role == "tool" then
    for _, part in ipairs(msg.content or {}) do
      if part.type == "tool_result" and part.call_id == "orphan1" then
        repaired = repaired + 1
        A.assert_eq(part.status, "cancelled", "restore: synthetic result cancelled")
        A.assert_eq(part.provenance, "restore_repair", "restore: provenance marker")
        A.check(part.is_error == true, "restore: synthetic result is_error")
      end
    end
  end
end
A.assert_eq(repaired, 1, "restore: exactly one synthetic result injected")
A.check(orphan_idx ~= nil and orphan_idx < orch2.messages:len(), "restore: synthetic result after owning assistant")
-- Messages: snapshot + 1 repair + 1 restore-request assistant reply.
A.assert_eq(orch2.messages:len(), snapshot_msg_count + 2, "restore: repair + restore reply only")
-- Idempotent: a second repair pass injects nothing.
A.assert_eq(orch2:_repair_orphan_tool_calls(), 0, "restore: repair idempotent")

-- No duplicate manual user trace: restore added no user message; the original
-- single user boundary is intact.
local user_count = 0
for msg in orch2.messages:iter() do
  if msg.role == "user" then
    user_count = user_count + 1
  end
end
A.assert_eq(user_count, 1, "restore: no duplicate manual user trace")

-------------------------------------------------------------------------------
-- Durable-key dedup after restore: replaying the SAME continuation decision
-- point recorded in the snapshot (same generation/request/batch/kind,
-- reconstructed from the restored decisions) is rejected — no duplicate
-- continuation, no duplicate events.
-------------------------------------------------------------------------------
local key, rec = next(st2.loop.decisions)
A.check(type(key) == "string", "restore: snapshot decision key present")
local cur1 = {
  request = {
    id = rec.source_request_id,
    generation = rec.session_generation,
    terminal = { state = "completed" },
  },
}
local batch1 = { id = rec.tool_batch_id, terminal = { state = "completed" } }
st2.loop.state = "armed" -- replay the same continue decision row as the snapshot
local before =
  { calls = prov2.call_count(), subs = rec2.count("request.submitted"), dec = rec2.count("continuation.decided") }
local replay = orch2:_decide_continuation(cur1, batch1)
A.check(replay ~= nil and replay.replayed == true, "restore: same-key decision after restore rejected (replayed)")
A.check(type(replay.record.key) == "string", "restore: existing record reference")
A.assert_eq(prov2.call_count(), before.calls, "restore: no duplicate continuation submit")
A.assert_eq(rec2.count("request.submitted"), before.subs, "restore: no repeated request.submitted")
A.assert_eq(rec2.count("continuation.decided"), before.dec, "restore: no repeated continuation.decided")
A.assert_eq(#st2.requests, 1, "restore: no duplicate request entity")

-- A fresh manual submit after restore works and adds exactly one user trace.
local manual = orch2:submit("continue after restore")
A.check(manual.rejected ~= true, "restore: manual submit accepted")
local user_count2 = 0
for msg in orch2.messages:iter() do
  if msg.role == "user" then
    user_count2 = user_count2 + 1
  end
end
A.assert_eq(user_count2, user_count + 1, "restore: manual submit adds exactly one user trace")

if A.ok then
  print("RESTORE_AGENT_LOOP_OK")
else
  error("RESTORE_AGENT_LOOP_FAILED count=" .. #A.failures)
end
