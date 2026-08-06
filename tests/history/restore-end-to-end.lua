-- filepath: tests/history/restore-end-to-end.lua
--- Phase-4 W4-B restore end-to-end (orchestrator integration, host-style):
---   * manual turn (sync, deterministic counting provider) -> host-style
---     snapshot composition (runtime_state = FULL Session:snapshot(), messages
---     = stack:to_table()) -> history:save;
---   * bundle = restore_bundle: runtime_state carries the session snapshot shape
---     (id/project_id/generation/state/active ids/loop/views) + service extras;
---   * NEW orchestrator + restore_agent_loop({session=bundle.runtime_state,
---     messages=bundle.messages}):
---       - messages round-trip identical (stack_from_table -> to_table);
---       - loop.decisions preserved (no duplicate continuation);
---       - orphan assistant tool_call (injected before save) repaired with a
---         synthetic cancelled result (provenance restore_repair);
---       - session parks at waiting_for_user;
---       - exactly the restore request ran (1 provider call) and NO further
---         automatic provider call happens after it (loop parked, no
---         continuation submit);
---   * service restore-support additions: bind(session_id, save_id),
---     bind_trace/trace_for, get_last_chat.
---
--- Fixture convention: prints HISTORY_OK: restore-end-to-end on success; throws.

local assert_mod = require("tests.history.lib.assert")
local fixture_project = require("tests.history.lib.fixture_project")
local history = require("maxa.runtime.history")
local events = require("maxa.runtime.events")
local orchestrator = require("maxa.runtime.orchestrator")
local protocol = require("maxa.runtime.protocol")
local conversation = require("maxa.runtime.conversation")

local ctx = assert_mod.new()
local A = assert_mod.new() -- deep-equality ctx

local mock = protocol.get(protocol.providers.mock)

-- Text-only counting provider: every call emits one deterministic reply.
local function text_provider(name)
  local calls = 0
  local prov = {
    name = name,
    protocol = "mock",
    capabilities = mock.capabilities,
  }
  function prov.stream(_, params, callbacks)
    calls = calls + 1
    params = vim.tbl_deep_extend("force", params or {}, { chunks = { "reply " .. calls } })
    return mock.stream(mock, params, callbacks)
  end
  function prov.call_count()
    return calls
  end
  return prov
end

fixture_project.with_project(function(proj)
  local service = history.new({ root = proj.root, events = events.new() })

  ---------------------------------------------------------------------------
  -- Source orchestrator: one manual turn, one injected durable decision, one
  -- injected orphan assistant tool_call (interrupted chain, no paired result).
  ---------------------------------------------------------------------------
  local prov1 = text_provider("src")
  local orch1 = orchestrator.new({ provider = prov1, events = events.new() })
  local res1 = orch1:submit("first question", { provider_params = { chunks = {} } })
  ctx.check(res1.rejected ~= true, "restore-e2e: manual turn accepted")
  ctx.assert_eq(res1.terminal_state, "completed", "restore-e2e: manual turn completed")
  ctx.assert_eq(prov1.call_count(), 1, "restore-e2e: manual turn = 1 provider call")
  ctx.assert_eq(orch1.session.loop.state, "waiting_for_user", "restore-e2e: source loop parked")

  -- Durable continuation decision (W5 dedup source).
  orch1.session.loop.decisions["e2e-d-1"] = {
    session_generation = orch1.session.generation,
    source_request_id = "req-e2e-1",
    tool_batch_id = nil,
    decision_kind = "wait",
  }
  local decision_keys = {}
  for k in pairs(orch1.session.loop.decisions) do
    decision_keys[#decision_keys + 1] = k
  end

  -- Orphan tool_call: appended by hand to the stack BEFORE the save (the
  -- restore must repair it).
  orch1.messages:add_message(
    { role = "assistant", content = { conversation.tool_call_part("orphan-e2e", "echo", "{}") } },
    { turn_id = "turn-orphan-e2e" }
  )
  local original_messages = orch1.messages:to_table()
  local original_count = #original_messages
  local session_snapshot = orch1.session:snapshot()

  ---------------------------------------------------------------------------
  -- Host-style durable snapshot composition (mirrors host/nvim
  -- view_durable_snapshot): runtime_state = FULL Session:snapshot().
  ---------------------------------------------------------------------------
  local snap = {
    session_id = orch1.session.id,
    project_id = orch1.session.project_id,
    generation = orch1.session.generation,
    provider_id = "mock",
    protocol = orch1.provider.protocol or "mock",
    model = orch1.model,
    title = "restore e2e",
    messages = original_messages,
    context_items = {},
    usage = nil,
    status_snapshot = { state = orch1.session.state, running = false, terminal = {} },
    runtime_state = session_snapshot,
    trace = {
      id = "trace-e2e",
      membership = { root_trace_id = "trace-e2e", span_id = "span-e2e", session_role = "root", active = true },
    },
  }
  local sv = service:save(snap)
  ctx.check(sv.ok == true, "restore-e2e: save ok (err=" .. tostring(sv.error) .. ")")

  local bundle, berr = service:restore_bundle(sv.save_id)
  ctx.check(bundle ~= nil and berr == nil, "restore-e2e: restore_bundle ok")
  ctx.check(bundle ~= nil, "restore-e2e: bundle present")
  if bundle then
    -- runtime_state round-trips the FULL Session:snapshot() shape (plus the
    -- service envelope extras cwd/project_root/usage — never dropped).
    ctx.assert_eq(bundle.runtime_state.id, session_snapshot.id, "restore-e2e: runtime_state.id round-trips")
    ctx.assert_eq(bundle.runtime_state.project_id, session_snapshot.project_id, "restore-e2e: runtime_state.project_id round-trips")
    ctx.assert_eq(bundle.runtime_state.generation, session_snapshot.generation, "restore-e2e: runtime_state.generation round-trips")
    ctx.assert_eq(bundle.runtime_state.state, "waiting_for_user", "restore-e2e: runtime_state.state round-trips")
    ctx.assert_eq(bundle.runtime_state.active_request_id, session_snapshot.active_request_id, "restore-e2e: active_request_id round-trips")
    ctx.assert_eq(bundle.runtime_state.active_tool_batch_id, session_snapshot.active_tool_batch_id, "restore-e2e: active_tool_batch_id round-trips")
    ctx.check(
      bundle.runtime_state.loop ~= nil and bundle.runtime_state.loop.decisions["e2e-d-1"] ~= nil,
      "restore-e2e: loop.decisions round-trips"
    )
    ctx.check(type(bundle.runtime_state.views) == "table", "restore-e2e: views array round-trips")
    ctx.assert_eq(bundle.runtime_state.cwd, proj.root, "restore-e2e: envelope cwd extra present")
    ctx.assert_eq(bundle.runtime_state.project_root, proj.root, "restore-e2e: envelope project_root extra present")
  end

  ---------------------------------------------------------------------------
  -- Restore into a FRESH orchestrator (the host restore flow).
  ---------------------------------------------------------------------------
  local prov2 = text_provider("dst")
  local orch2 = orchestrator.new({ provider = prov2, events = events.new() })
  local rres = orch2:restore_agent_loop({ session = bundle.runtime_state, messages = bundle.messages })
  ctx.check(rres ~= nil and rres.rejected ~= true, "restore-e2e: restore accepted")

  -- Exactly the restore request ran (kind=restore, empty text): ONE provider
  -- call, then the loop parks at waiting_for_user — no continuation submit,
  -- no further automatic provider call.
  ctx.assert_eq(prov2.call_count(), 1, "restore-e2e: exactly the restore request ran")
  local st2 = orch2.session
  ctx.assert_eq(st2.id, orch1.session.id, "restore-e2e: session identity preserved")
  ctx.assert_eq(st2.loop.state, "waiting_for_user", "restore-e2e: loop parked at waiting_for_user")
  ctx.check(st2.loop.enabled == true, "restore-e2e: loop enabled")
  for _, k in ipairs(decision_keys) do
    ctx.check(st2.loop.decisions[k] ~= nil, "restore-e2e: durable decision " .. k .. " preserved")
  end
  ctx.assert_eq(prov2.call_count(), 1, "restore-e2e: no further provider call after park")

  -- Messages round-trip: the first original_count messages are deep-identical;
  -- the restore appended exactly repair + restore reply.
  local restored_table = orch2.messages:to_table()
  ctx.assert_eq(#restored_table, original_count + 2, "restore-e2e: repair + restore reply appended")
  A.assert_same_table(restored_table[1], original_messages[1], "restore-e2e: message[1] identical")
  A.assert_same_table(restored_table[2], original_messages[2], "restore-e2e: message[2] identical")
  A.assert_same_table(restored_table[original_count], original_messages[original_count], "restore-e2e: last original message identical")

  -- Orphan repair: exactly one synthetic cancelled result for orphan-e2e.
  local repaired = 0
  for _, msg in ipairs(restored_table) do
    if msg.role == "tool" then
      for _, part in ipairs(msg.content or {}) do
        if part.type == "tool_result" and part.call_id == "orphan-e2e" then
          repaired = repaired + 1
          ctx.assert_eq(part.status, "cancelled", "restore-e2e: synthetic result cancelled")
          ctx.assert_eq(part.provenance, "restore_repair", "restore-e2e: provenance marker")
        end
      end
    end
  end
  ctx.assert_eq(repaired, 1, "restore-e2e: exactly one synthetic result injected")

  ---------------------------------------------------------------------------
  -- Service restore-support additions (W4-B): bind / bind_trace / trace_for /
  -- get_last_chat — the host restore flow calls these for save->close->reopen
  -- continuity.
  ---------------------------------------------------------------------------
  service:bind(st2.id, sv.save_id)
  ctx.assert_eq(service:current_save_id(st2.id), sv.save_id, "restore-e2e: bind(session_id, save_id)")
  service:bind_trace(st2.id, bundle.trace)
  local tr = service:trace_for(st2.id)
  ctx.check(tr ~= nil, "restore-e2e: trace_for returns bound trace")
  if tr then
    ctx.assert_eq(tr.id, "trace-e2e", "restore-e2e: trace id rebound")
    ctx.assert_eq(tr.membership.span_id, "span-e2e", "restore-e2e: trace membership rebound")
  end
  local last = service:get_last_chat()
  ctx.check(last ~= nil and last.save_id == sv.save_id, "restore-e2e: get_last_chat returns the saved chat")
  -- bind refuses unsavable ids (defensive contract).
  service:bind(st2.id, "_cc_history_unsavable_scratch/x")
  ctx.assert_eq(service:current_save_id(st2.id), sv.save_id, "restore-e2e: bind rejects unsavable id")
end)

if not ctx.ok then
  error("restore-end-to-end failed: " .. table.concat(ctx.failures, "; "), 0)
end
print("HISTORY_OK: restore-end-to-end")
