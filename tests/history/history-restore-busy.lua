-- filepath: tests/history/history-restore-busy.lua
--- Phase-4 MaxaHistory busy-snapshot resilience (headless):
---   * a saved session whose runtime_state.state is "busy" (snapshot taken
---     while a request was in flight / racing close-save) must restore
---     WITHOUT error: the host normalizes the state to waiting_for_user,
---     drops the dangling active ids, shows the chat and opens the window;
---   * the restored session is idle (waiting_for_user), the persisted
---     messages are intact, and no phantom request is replayed.
---
--- Fixture convention: prints HISTORY_OK: history-restore-busy; throws.

local assert_mod = require("tests.history.lib.assert")
local fixture_project = require("tests.history.lib.fixture_project")
local history = require("maxa.runtime.history")
local events = require("maxa.runtime.events")
local host = require("maxa.runtime.host.nvim")
local session_mod = require("maxa.runtime.session")

local ctx = assert_mod.new()

fixture_project.with_project(function(proj)
  local bus = events.new()
  local service = history.new({ root = proj.root, events = bus, config = { auto_save = false } })
  host.set_defaults({
    history = service,
    history_config = { enabled = true, auto_save = false, continue_last = false },
  })

  -- Build a session normally (one answered turn), then save a SNAPSHOT whose
  -- runtime_state carries state="busy" + dangling active ids — exactly what a
  -- save racing an in-flight request persists (auto_save on a terminal event
  -- before the session transition, or close-save while busy).
  local v1 = host._get_default()
  local ok1 = v1:submit("hello", { provider_params = { chunks = { "world" } } })
  ctx.check(ok1.rejected ~= true, "restore-busy: turn accepted")

  local conv = require("maxa.runtime.conversation")
  local snapshot = {
    session_id = v1.orch.session.id,
    project_id = "fixture",
    generation = 2,
    provider_id = "mock",
    protocol = "mock",
    model = "mock-model",
    title = nil,
    messages = v1.orch:_stack():to_table(),
    context_items = {},
    runtime_state = {
      id = v1.orch.session.id,
      project_id = "fixture",
      generation = 2,
      state = session_mod.states.busy, -- busy snapshot (in-flight when saved)
      active_request_id = "req-in-flight",
      active_tool_batch_id = "batch-in-flight",
      loop = { enabled = true, state = "armed", iteration = 1, decision_key = nil, decisions = {} },
      views = {},
    },
  }
  local sres = service:save(snapshot, { save_id = "busy-session" })
  ctx.check(sres.ok == true and sres.save_id == "busy-session", "restore-busy: busy snapshot saved")
  ctx.check(service:current_save_id(v1.orch.session.id) == "busy-session", "restore-busy: bound")

  -- Switch away (fresh view), then restore the busy snapshot: MUST NOT error.
  v1:close()
  host._default = nil
  local v_other = host._get_default()
  ctx.check(v_other ~= nil, "restore-busy: fresh view created")

  local v2 = host.restore_chat("busy-session")
  ctx.check(v2 ~= nil, "restore-busy: busy snapshot restores without rejection")
  ctx.check(v2._opened == true, "restore-busy: restored window is open (chat shown + focused)")
  ctx.check(
    v2.orch.session.state == session_mod.states.waiting_for_user,
    "restore-busy: restored session normalized to idle (waiting_for_user)"
  )
  ctx.check(
    v2.orch.session.active_request_id == nil and v2.orch.session.active_tool_batch_id == nil,
    "restore-busy: dangling active ids dropped"
  )
  local n = v2.orch:_stack():len()
  ctx.check(n >= 2, "restore-busy: persisted messages intact")
  local last = v2.orch:_stack():get(n)
  ctx.check(last ~= nil and last.role == "assistant", "restore-busy: last message is the assistant reply")
  -- No phantom request: the orchestrator is not busy.
  ctx.check(v2.orch:is_busy() == false, "restore-busy: no phantom request replayed")

  -- Repeated restore of the SAME session is a no-op (focus already there).
  local noop = host.restore_chat("busy-session")
  ctx.check(noop == nil, "restore-busy: re-restoring the active session is a no-op")

  v2:close()
  host._default = nil
  host._history = nil
  host._history_config = nil
  host._history_listening = false
  service:dispose()
end)

if not ctx.ok then
  error("history-restore-busy failed: " .. table.concat(ctx.failures, "; "), 0)
end
print("HISTORY_OK: history-restore-busy")
