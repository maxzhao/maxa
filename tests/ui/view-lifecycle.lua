-- filepath: tests/ui/view-lifecycle.lua
-- phase-5 W3 chat view lifecycle headless validation (chat-ui spec §View
-- lifecycle / §View model / §Input):
--   A. hide: hides the window but KEEPS the attachment + session alive (submit
--      still works while hidden); open() re-shows idempotently; chat.hidden
--      fired with view_id/session_id payload.
--   B. close_view (close view, NOT close session): _ui_closed == true,
--      status ~= "closed", session alive (orch NOT closed), view.closed fired;
--      M.open()/reattach reopen the SAME session (id unchanged, messages kept).
--   C. close (close session): existing semantics preserved (status == "closed",
--      orchestrator session closed).
--   D. reattach: full snapshot render equivalence (_build line set identical);
--      a late callback fired after the old buffer was deleted does not render
--      into the new buffer and does not error (buffer-validity guard).
--   E. input revision: _input_revision bumps on accepted submits; snapshot
--      exposes input_revision/last_submitted_revision; the accepted capture
--      carries text + context_ids (mock assertions).
--   F. safe provider/model switch: while busy set_provider/set_model return
--      false, provider/model unchanged, errors recorded; idle succeeds.
--   G. context picker: candidates exist (mock scenario); the picked item is
--      submitted with context_ids.
--   H. terminal import-guard assert (nothing legacy loaded).
--
-- Run: NVIM_APPNAME=nvim-maxa nvim --headless -c "lua vim.defer_fn(function()
--   local d='<root>/tests/ui/view-lifecycle.lua' local ok=pcall(dofile,d)
--   vim.cmd(ok and 'qa!' or 'cq') end, 2000)"
-- Exit 0 on success; 1 (cq) on any failed assertion.

local ok_all = true
local failures = {}

local function check(cond, msg)
  if not cond then
    ok_all = false
    failures[#failures + 1] = msg
    print("VIEW_LIFECYCLE_FAIL: " .. msg)
  end
end

local function assert_eq(got, want, msg)
  if got ~= want then
    check(false, ("%s (got %s, want %s)"):format(msg, vim.inspect(got), vim.inspect(want)))
  end
end

local host = require("maxa.runtime.host.nvim")
local events = require("maxa.runtime.events")

local function wait_for(deadline_ms, is_done)
  local waited = 0
  while waited < deadline_ms do
    if is_done() then
      return true
    end
    vim.wait(20)
    waited = waited + 20
  end
  return is_done()
end

-- A window counts as hidden when it was destroyed (nvim_win_hide float
-- fallback) OR its config.hide is true (snacks layout hide path).
local function window_hidden(win)
  if not win or not vim.api.nvim_win_is_valid(win) then
    return true
  end
  return vim.api.nvim_win_get_config(win).hide == true
end

-- Shallow structural equality for line-set comparisons (string tables).
local function lines_equal(a, b)
  if #a ~= #b then
    return false
  end
  for i = 1, #a do
    if a[i] ~= b[i] then
      return false
    end
  end
  return true
end

--- Bind scratch chat buffer + current window to the view (mirrors View:open's
--- window pair without the snacks layout; used where the tests drive UI-less
--- lifecycle paths directly).
local function bind_view(v)
  local chat = vim.api.nvim_create_buf(false, true)
  vim.bo[chat].buftype = "nofile"
  vim.bo[chat].swapfile = false
  vim.bo[chat].modifiable = true
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, chat)
  v:_bind_render_buffer(chat, win)
  v._buf = chat
  v._chat_win = win
  v._opened = true
  v:_init_input_area()
  v:_add_input_mappings()
  v:_refresh_input_intro()
  return chat, win
end

--------------------------------------------------------------------------------
-- A. hide: window hidden, attachment + session kept, chat.hidden fired
--------------------------------------------------------------------------------
do
  local bus = events.new()
  local v = host.new({ provider = "mock", events = bus })
  local hidden_count = 0
  local hidden_payload = nil
  bus.on(bus.events.chat_hidden, function(payload)
    hidden_count = hidden_count + 1
    hidden_payload = payload
  end)
  local ok_open = v:open()
  check(ok_open, "A: open() created the layout")
  local sid = v.orch.session.id
  local win = v._chat_win
  check(win ~= nil and vim.api.nvim_win_is_valid(win), "A: chat window valid before hide")

  local ok_hide = v:hide()
  check(ok_hide, "A: hide() performed")
  check(v._hidden == true, "A: _hidden flag set")
  check(v._opened == true, "A: _opened kept (attachment preserved)")
  check(not v:_is_closed_view(), "A: view NOT session-closed after hide")
  check(window_hidden(win), "A: chat window hidden (config.hide or destroyed)")
  check(hidden_count == 1, "A: chat.hidden fired exactly once")
  check(hidden_payload ~= nil and hidden_payload.session_id == sid, "A: chat.hidden payload carries session_id")

  -- Session alive: submit still works while hidden (attachment preserved).
  local r = v:submit("after hide", { provider_params = { chunks = { "still works" } } })
  check(r.rejected ~= true, "A: submit while hidden accepted")
  check(v.orch.session.id == sid, "A: session id unchanged while hidden")

  -- open() restores idempotently (re-shown in place, or rebuilt when the
  -- float fallback destroyed the window).
  local ok_restore = v:open()
  check(ok_restore, "A: open() restores")
  check(v._hidden == false, "A: _hidden cleared after open()")
  check(v._opened == true, "A: reopened")
  check(v._chat_win ~= nil and vim.api.nvim_win_is_valid(v._chat_win), "A: a valid chat window exists after open()")
  check(not window_hidden(v._chat_win), "A: restored window visible")
  v:close()
end

--------------------------------------------------------------------------------
-- B. close_view: view resources disposed, session ALIVE, same-session reopen
--------------------------------------------------------------------------------
do
  local bus = events.new()
  local v = host.new({ provider = "mock", events = bus })
  local chat = bind_view(v)
  local sid = v.orch.session.id
  v:submit("keep me", { provider_params = { chunks = { "saved" } } })
  local closed_count = 0
  local closed_payload = nil
  bus.on(bus.events.view_closed, function(payload)
    closed_count = closed_count + 1
    closed_payload = payload
  end)

  local ok_cv = v:close_view()
  check(ok_cv, "B: close_view() performed")
  check(v._ui_closed == true, "B: _ui_closed set")
  check(v.status ~= "closed", "B: view status NOT closed (session stays alive)")
  check(v._buf == nil, "B: UI buffer ref dropped")
  check(v.orch.session.id == sid, "B: same session id")
  check(v.orch.session:is_closed() == false, "B: orchestrator session NOT closed")
  check(closed_count == 1, "B: view.closed fired exactly once")
  check(closed_payload ~= nil and closed_payload.session_id == sid, "B: view.closed payload carries session_id")

  -- Reopen the SAME session via M.open() (close-view reopen semantics).
  local prev_default = host._default
  host._default = v
  local reopened = host.open()
  check(reopened == v, "B: M.open() reopens the same view instance")
  check(reopened._opened == true, "B: reopened UI built")
  check(reopened._ui_closed == false, "B: _ui_closed cleared after reopen")
  check(reopened.orch.session.id == sid, "B: reopened session id unchanged")
  local msgs = reopened.orch.messages:to_table()
  check(#msgs >= 2, "B: messages preserved after close_view + reopen (got " .. #msgs .. ")")
  check(not reopened:_is_closed_view(), "B: reopened view not session-closed")
  reopened:close()
  host._default = prev_default
end

--------------------------------------------------------------------------------
-- C. close (close session): existing semantics preserved
--------------------------------------------------------------------------------
do
  local v = host.new({ provider = "mock", events = events.new() })
  bind_view(v)
  v:submit("x", { provider_params = { chunks = { "y" } } })
  local changed = v:close()
  check(changed, "C: close() changed")
  check(v.status == "closed", "C: status == closed after close()")
  check(v:_is_closed_view(), "C: _is_closed_view() true after close()")
  check(v.orch.session:is_closed(), "C: orchestrator session closed after close()")
  check(v:open() == false, "C: open() refused on a closed view")
end

--------------------------------------------------------------------------------
-- D. reattach: full snapshot render equivalence + late-callback guard
--------------------------------------------------------------------------------
do
  local bus = events.new()
  local v = host.new({ provider = "mock", events = bus })
  local chat = bind_view(v)
  v:submit("hello", { provider_params = { chunks = { "world" } } })
  local before = v:_build_lines()
  check(#before > 0, "D: render produced lines before reattach")
  local reattached_count = 0
  bus.on(bus.events.chat_reattached, function()
    reattached_count = reattached_count + 1
  end)

  -- Delete the old buffer. Headless note: nvim_buf_delete does NOT fire
  -- BufDelete autocmds, so the view-level detach (the exact autocmd callback
  -- action) is invoked explicitly to drop the UI refs deterministically —
  -- production fires it via the buffer-delete autocmd.
  vim.api.nvim_buf_delete(chat, { force = true })
  v:detach("buffer deleted")
  check(v._buf == nil, "D: buffer ref dropped after delete")

  -- Late callback from the OLD generation: must not error (the render path is
  -- guarded by buffer validity; the detached view model may keep receiving —
  -- W8 view-delete semantics — but reattach re-syncs from the session stack,
  -- so the stale late text never appears in the new generation).
  local ok_delta = pcall(function()
    v:_on_delta({ text = "late" })
  end)
  check(ok_delta, "D: late _on_delta after buffer delete does not error")

  -- Reattach: new view generation + full snapshot render (equivalent lines).
  local ok_ra = v:reattach()
  check(ok_ra, "D: reattach() performed")
  check(reattached_count == 1, "D: chat.reattached fired exactly once")
  local after = v:_build_lines()
  check(lines_equal(before, after), "D: full snapshot render equivalent before/after reattach")
  -- The late text never made it into the new generation's render.
  local joined = table.concat(after, "\n")
  check(joined:find("late", 1, true) == nil, "D: late callback text absent from reattached render")
  check(v.orch.session:is_closed() == false, "D: session still alive after reattach")
  v:close()
end

--------------------------------------------------------------------------------
-- E. input revision: atomic capture bumps on accepted submits only
--------------------------------------------------------------------------------
do
  local v = host.new({ provider = "mock", events = events.new() })
  assert_eq(v._input_revision, 0, "E: initial input revision 0")
  assert_eq(v._last_submitted_revision, nil, "E: no submitted revision yet")
  local s0 = v:snapshot()
  assert_eq(s0.input_revision, 0, "E: snapshot input_revision initial")
  assert_eq(s0.last_submitted_revision, nil, "E: snapshot last_submitted_revision initial")
  assert_eq(#s0.context_ids, 0, "E: snapshot context_ids empty initially")

  local r1 = v:submit("first", { provider_params = { chunks = { "a" } } })
  check(r1.rejected ~= true, "E: first submit accepted")
  assert_eq(v._input_revision, 1, "E: input revision bumped after accepted submit")
  assert_eq(v._last_submitted_revision, 0, "E: last submitted revision 0")
  local s1 = v:snapshot()
  assert_eq(s1.input_revision, 1, "E: snapshot input_revision after submit")
  assert_eq(s1.last_submitted_revision, 0, "E: snapshot last_submitted_revision after submit")

  -- Accepted capture carries text + context_ids (mock assertion).
  local r2 = v:submit("second", {
    context_ids = { "ctx-1" },
    provider_params = { chunks = { "b" } },
  })
  check(r2.rejected ~= true, "E: second submit with context accepted")
  assert_eq(v._input_revision, 2, "E: input revision bumped again")
  assert_eq(v._last_submitted_revision, 1, "E: last submitted revision 1")
  check(
    #v._submitted_context == 1 and v._submitted_context[1].id == "ctx-1",
    "E: submitted context captured (id ctx-1)"
  )
  check(
    v._submitted_context[1].kind == "context" and v._submitted_context[1].source == "submission",
    "E: submitted context minimal shape (kind/source)"
  )
  local s2 = v:snapshot()
  assert_eq(s2.input_revision, 2, "E: snapshot input_revision after second submit")
  check(#s2.context_ids == 1 and s2.context_ids[1] == "ctx-1", "E: snapshot context_ids from accepted capture")
  check(#v._pending_context == 0, "E: pending context consumed on submit")
  v:close()
end

--------------------------------------------------------------------------------
-- F. safe provider/model switch: busy rejected, idle accepted
--------------------------------------------------------------------------------
do
  local chunks = {}
  for i = 1, 30 do
    chunks[i] = "chunk-" .. i .. " "
  end
  local v = host.new({
    provider = "mock",
    events = events.new(),
    provider_params = { chunks = chunks, delay = 20 },
  })
  v:submit("hello", { async = true })
  local busy = wait_for(5000, function()
    return v.orch:is_busy()
  end)
  check(busy, "F: session reached busy")
  local p_before = v.provider_name
  local m_before = v.model
  local n_errors = #v.errors

  check(v:set_provider("echo") == false, "F: set_provider rejected while busy")
  assert_eq(v.provider_name, p_before, "F: provider unchanged while busy")
  check(v:set_model("other-model") == false, "F: set_model rejected while busy")
  assert_eq(v.model, m_before, "F: model unchanged while busy")
  check(#v.errors > n_errors, "F: typed error recorded on busy rejection")
  check(v.orch:is_busy(), "F: in-flight request untouched by rejections")

  local done = wait_for(8000, function()
    return v.status == "completed"
  end)
  check(done, "F: stream completed")
  check(v:set_provider("echo") == true, "F: set_provider accepted when idle")
  assert_eq(v.provider_name, "echo", "F: provider switched when idle")
  check(v:set_model("new-model") == true, "F: set_model accepted when idle")
  assert_eq(v.model, "new-model", "F: model switched when idle")
  v:close()
end

--------------------------------------------------------------------------------
-- G. context picker: candidates exist, picked item submitted via context_ids
--------------------------------------------------------------------------------
do
  local v = host.new({ provider = "mock", events = events.new() })
  bind_view(v)
  -- Give the current buffer a file name so the picker has a file candidate.
  vim.api.nvim_buf_set_name(0, "/tmp/maxa-demo-file.lua")
  local seen = nil
  local orig_select = vim.ui.select
  vim.ui.select = function(items, opts, cb)
    seen = items
    cb(items[1]) -- simulate an immediate pick of the first candidate
  end
  local ok_pcall = pcall(function()
    v:_pick_context()
  end)
  vim.ui.select = orig_select
  check(ok_pcall, "G: _pick_context did not error")
  check(type(seen) == "table" and #seen >= 1, "G: context candidates exist (got " .. (seen and #seen or "nil") .. ")")
  check(seen[1].kind == "file" and seen[1].source == "buffer", "G: buffer/file candidate shape")
  check(#v._pending_context == 1, "G: picked item added to pending context")
  local ctx_id = v._pending_context[1].id
  check(type(ctx_id) == "string" and ctx_id ~= "", "G: pending context id present")

  -- Submit with context_ids selecting the picked item.
  local r = v:submit("with context", {
    context_ids = { ctx_id },
    provider_params = { chunks = { "ok" } },
  })
  check(r.rejected ~= true, "G: submit with picked context accepted")
  check(
    #v._submitted_context == 1 and v._submitted_context[1].id == ctx_id,
    "G: picked context carried by the accepted submission"
  )
  check(#v._pending_context == 0, "G: pending context consumed after submit")
  v:close()
end

--------------------------------------------------------------------------------
-- I. Global restore entries after hide (2026-08-06 user finding): the chat
-- buffer-local `gr` is UNREACHABLE once the window is hidden, so the restore
-- contract is the global `:MaxaChat` (M.open) and `:MaxaReattach` (M.reattach)
-- paths — both must restore the SAME session instead of closing it.
--------------------------------------------------------------------------------
do
  local bus = events.new()
  local v = host.new({ provider = "mock", events = bus })
  local ok_open = v:open()
  check(ok_open, "I: open() created the layout")
  local sid = v.orch.session.id
  -- Simulate :MaxaChat default-view wiring (continue_last disabled).
  host._default = v
  local ok_hide = v:hide()
  check(ok_hide, "I: hide() performed")
  check(v._hidden == true, "I: hidden flag set")
  -- :MaxaChat must restore the same session, not close it.
  local restored = host.open()
  check(restored == v, "I: M.open() returns the hidden default view")
  check(v._hidden == false, "I: M.open() cleared _hidden")
  check(v.orch.session.id == sid, "I: M.open() kept the same session")
  check(not v:_is_closed_view(), "I: session NOT closed by M.open()")
  -- Hide again, then the global :MaxaReattach path restores over the same
  -- session with a fresh UI generation.
  v:hide()
  check(v._hidden == true, "I: re-hidden")
  local ok_reattach = host.reattach()
  check(ok_reattach, "I: M.reattach() restored")
  check(v._hidden == false and v._ui_closed == false, "I: M.reattach() cleared hidden/ui_closed")
  check(v.orch.session.id == sid, "I: M.reattach() kept the same session")
  check(v._chat_win ~= nil and vim.api.nvim_win_is_valid(v._chat_win), "I: valid window after M.reattach()")
  v:close()
  host._default = nil
end
--------------------------------------------------------------------------------
-- H. Terminal import-guard assert (nothing legacy loaded)
--------------------------------------------------------------------------------
do
  local guard = require("maxa.runtime.guard")
  check(guard.assert_no_forbidden(), "H: import-guard: no legacy families loaded")
end

if ok_all then
  print("UI_VIEW_LIFECYCLE_OK")
else
  print("UI_VIEW_LIFECYCLE_FAILED count=" .. #failures)
  vim.cmd("cq")
end
return ok_all
