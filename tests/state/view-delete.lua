-- filepath: tests/state/view-delete.lua
--- Phase-2 W8 fixture: buffer deletion detaches the view and preserves the
--- session/request (async-lifecycle §Cancellation and cleanup); callbacks never
--- touch an invalid buffer.
---
--- Assertions (runtime-fixture-contract async/view-delete):
---   * session View entity: attached -> detached (via Session:detach_view,
---     idempotent) and detached -> closed (via Session:close_view, idempotent);
---   * detach NEVER closes the session: an in-flight/completed request
---     continues, a later submit proceeds, the snapshot shows the detached
---     view;
---   * host View (headless): the buffer number is bound to the session view
---     entity; detach drops ALL UI references and rendering becomes inert —
---     _render() with no buffer is a safe no-op, bus callbacks after detach do
---     not crash and do not mutate any buffer (only the view-local model),
---     projection() stays pure state;
---   * ownership: a closed view rejects further work (submit/stop return
---     typed no-ops), and a detach on a closed view is a no-op.
---
--- Fixture convention: prints VIEW_DELETE_OK on success; throws.

local assert_mod = require("tests.state.lib.assert")
local recorder = require("tests.state.lib.recorder")
local events = require("maxa.runtime.events")
local session = require("maxa.runtime.session")
local host = require("maxa.runtime.host.nvim")
local normalize = require("maxa.runtime.protocol.normalize")

local A = assert_mod.new()

-- Part A: session-level view entity semantics (runtime ownership).
do
  local bus = events.new()
  local s = session.new({ events = bus })
  local v = s:new_view({ view_id = "v-session-1", bufnr = 42 })
  A.check(v ~= nil, "vd-a: view created")
  A.assert_eq(v.state, "attached", "vd-a: view attached")
  A.assert_eq(v.bufnr, 42, "vd-a: bufnr bound")

  A.check(s:detach_view(v, "buffer deleted") == true, "vd-a: detach performed")
  A.assert_eq(v.state, "detached", "vd-a: view detached")
  A.check(s:detach_view(v, "again") == false, "vd-a: repeated detach is a no-op")
  A.check(s:is_closed() == false, "vd-a: session survives detach")
  A.assert_eq(s:snapshot().views[1].state, "detached", "vd-a: snapshot shows detached view")

  A.check(s:close_view(v, "view close") == true, "vd-a: close performed")
  A.assert_eq(v.state, "closed", "vd-a: view closed")
  A.check(s:close_view(v, "again") == false, "vd-a: repeated close is a no-op")
  A.check(s:is_closed() == false, "vd-a: closing a view never closes the session")

  -- A request can run while the view is detached (session/request continue).
  local s2 = session.new({ events = events.new() })
  local v2 = s2:new_view({ view_id = "v-session-2", bufnr = 7 })
  local req = s2:start_request({ intent = "manual" })
  A.check(req ~= nil, "vd-a: request started while view attached")
  A.check(s2:detach_view(v2, "buffer deleted") == true, "vd-a: detach while busy")
  A.assert_eq(s2.state, "busy", "vd-a: session still busy after detach")
  A.check(s2:finish_request(req, "completed"), "vd-a: request completes after detach")
  A.assert_eq(req.terminal.state, "completed", "vd-a: request terminal completed")
  A.assert_eq(s2.state, "waiting_for_user", "vd-a: session waiting_for_user after detach")
end

-- Part B: host View (headless) — buffer-delete detach semantics + inert render.
do
  local bus = events.new()
  local view = host.new({ events = bus })
  A.check(view.status == "idle", "vd-b: view starts idle")
  A.check(view._session_view == nil, "vd-b: no session view before attach")

  -- Attach a synthetic buffer (open() does this with the real buffer; headless
  -- tests attach a bufnr without creating a window pair).
  local sv = view:_attach_session_view(999)
  A.check(sv ~= nil, "vd-b: session view attached")
  A.assert_eq(sv.bufnr, 999, "vd-b: bufnr bound")
  A.assert_eq(sv.state, "attached", "vd-b: session view attached")
  A.check(view:_attach_session_view(999) == sv, "vd-b: re-attach reuses the entity")

  -- A full submit runs to completion; the session/request are alive.
  local res = view:submit("hello view", { provider_params = { chunks = { "hi" } } })
  A.assert_eq(res.terminal_state, "completed", "vd-b: submit completed")
  A.assert_eq(view.orch.session.state, "waiting_for_user", "vd-b: session waiting_for_user")

  -- Buffer deletion -> detach. UI refs dropped; session/request untouched.
  local detached = view:detach("buffer deleted")
  A.check(detached == true, "vd-b: detach performed")
  A.assert_eq(sv.state, "detached", "vd-b: session view detached")
  A.check(view.orch.session:is_closed() == false, "vd-b: session survives buffer delete")
  A.check(view._buf == nil and view._layout == nil, "vd-b: UI refs dropped")
  A.check(view:detach("again") == false, "vd-b: repeated detach no-op")

  -- Rendering with no valid buffer is a safe no-op (no invalid-buffer mutation).
  local ok_render, err_render = pcall(view._render, view)
  A.check(ok_render == true, "vd-b: _render safe with no buffer (" .. tostring(err_render) .. ")")

  -- Bus callbacks after detach still update the view-local model but never
  -- touch a buffer; projection stays pure.
  bus.emit("message.delta", {
    session_id = view.orch.session.id,
    request_id = "x",
    generation = 1,
    delta = "late delta",
    text = "late delta",
  })
  local ok_proj, proj = pcall(view.projection, view)
  A.check(ok_proj == true and type(proj) == "table", "vd-b: projection pure after detach")
  local last = view.items[#view.items]
  A.check(
    last ~= nil and last.role == "assistant" and (last.text or ""):find("late delta", 1, true) ~= nil,
    "vd-b: view model keeps receiving after detach"
  )

  -- The session continues: a second submit proceeds after detach.
  local res2 = view:submit("still alive", { provider_params = { chunks = { "ok" } } })
  A.assert_eq(res2.terminal_state, "completed", "vd-b: session continues after detach")

  -- Explicit close: session destroyed, session view closed, view closed.
  local closed = view:close()
  A.check(closed == true, "vd-b: close performed")
  A.check(view.orch.session:is_closed(), "vd-b: session closed")
  A.assert_eq(sv.state, "closed", "vd-b: session view closed")
  A.assert_eq(view.status, "closed", "vd-b: view status closed")
  A.check(view:detach("after close") == false, "vd-b: detach on closed view no-op")
  local res3 = view:submit("nope", {})
  A.check(res3.rejected == true, "vd-b: closed view rejects submit")
  A.check(view:close() == false, "vd-b: repeated close no-op")
end

if A.ok then
  print("VIEW_DELETE_OK")
else
  error("VIEW_DELETE_FAILED count=" .. #A.failures)
end
