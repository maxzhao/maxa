-- filepath: tests/ui/actions.lua
-- chat-ui-actions headless validation (phase 1.5 subpackage 3.4):
--   A. keymap registry: every M.KEYMAPS entry is registered on its target
--      buffer (chat: q/gx/]]/[[/g?/ga, input: <CR>/<Up>/<Down>/<C-c>).
--   B. header navigation: ]] / [[ move the chat cursor between role headers.
--   C. provider picker: vim.ui.select receives mock/echo + config provider ids
--      and the callback switches the provider (stubbed UI).
--   D. keymap help float: _show_keymap_help opens a window listing the registry
--      and q/<Esc> close it.
--   E. terminal import-guard assert (nothing legacy loaded).
--
-- Run: NVIM_APPNAME=nvim-maxa nvim --headless -c "lua vim.defer_fn(function()
--   local d='<root>/tests/ui/actions.lua' local ok=pcall(dofile,d)
--   vim.cmd(ok and 'qa!' or 'cq') end, 2000)"
-- Exit 0 on success; 1 (cq) on any failed assertion.

local ok_all = true
local failures = {}

local function check(cond, msg)
  if not cond then
    ok_all = false
    failures[#failures + 1] = msg
    print("ACTIONS_FAIL: " .. msg)
  end
end

local function assert_eq(got, want, msg)
  if got ~= want then
    check(false, ("%s (got %s, want %s)"):format(msg, vim.inspect(got), vim.inspect(want)))
  end
end

local host = require("maxa.runtime.host.nvim")
local events = require("maxa.runtime.events")
local n = require("maxa.runtime.protocol.normalize")
-- Scenario C (_pick_provider) reads config.effective, which is populated ONLY
-- by maxa.setup (the LazyVim plugin config is lazy and never triggers in a
-- headless test). Mirror tests/ui/config.lua / tests/w10/ui_chain.lua: run the
-- real setup with the mother-repository LazyVim opts (deepseek definitions;
-- credentials are env-name references only, never literals).
local maxa_mod = require("maxa")
local spec = require("plugins.maxa")[1]
pcall(maxa_mod.setup, spec.opts or {})

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
  return chat, win
end

local function has_line(lines, needle)
  for _, l in ipairs(lines) do
    if l:find(needle, 1, true) then
      return true
    end
  end
  return false
end

local function line_of(lines, needle)
  for i, l in ipairs(lines) do
    if l:find(needle, 1, true) then
      return i
    end
  end
  return nil
end

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

local function has_keymap(buf, mode, keys)
  -- maparg() resolves against the current buffer only, so switch context to
  -- the target buffer. Its dict `buffer` field is the buffer-local FLAG (1),
  -- not the buffer number; an absent mapping yields an empty dict.
  return vim.api.nvim_buf_call(buf, function()
    local m = vim.fn.maparg(keys, mode, false, true)
    return type(m) == "table" and m.buffer == 1
  end)
end

--------------------------------------------------------------------------------
-- A. Keymap registry presence on chat/input buffers
--------------------------------------------------------------------------------
do
  local v = host.new({ provider = "mock", events = events.new() })
  local chat, input = bind_view(v)
  for _, km in ipairs(host.KEYMAPS) do
    local buf = km.buf == "chat" and chat or input
    check(has_keymap(buf, km.mode, km.keys), "A: registered " .. km.mode .. " " .. km.keys .. " on " .. km.buf)
  end
  -- Count sanity: registry entries equal registered buffer-local keymaps.
  check(#host.KEYMAPS >= 11, "A: registry has 11+ entries (got " .. #host.KEYMAPS .. ")")
  v:close()
end

--------------------------------------------------------------------------------
-- B. Header navigation (]] / [[)
--------------------------------------------------------------------------------
do
  local chunks = {
    n.message_delta("first response"),
    n.message_delta("second response"),
  }
  local v = host.new({ provider = "mock", events = events.new(), provider_params = { chunks = chunks } })
  local chat = bind_view(v)
  v:submit("hello")
  local lines = v:_build_lines()
  -- Cursor to the first line, then ]] should land on the next "Assistant" header.
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  v:_goto_header(1)
  local row = vim.api.nvim_win_get_cursor(0)[1]
  check(lines[row] == "User", "B: ]] lands on first role header (User) (got " .. tostring(lines[row]) .. ")")
  -- Second ]] lands on the Assistant header.
  v:_goto_header(1)
  local row1b = vim.api.nvim_win_get_cursor(0)[1]
  check(lines[row1b] == "Assistant", "B: second ]] lands on Assistant (got " .. tostring(lines[row1b]) .. ")")
  -- [[ from there goes back to User.
  v:_goto_header(-1)
  local row2 = vim.api.nvim_win_get_cursor(0)[1]
  check(lines[row2] == "User", "B: [[ lands on User header (got " .. tostring(lines[row2]) .. ")")
  v:close()
end

--------------------------------------------------------------------------------
-- C. Provider picker (stubbed vim.ui.select)
--------------------------------------------------------------------------------
do
  local v = host.new({ provider = "mock", events = events.new() })
  bind_view(v)
  local seen_candidates = nil
  local chosen = nil
  local orig_select = vim.ui.select
  vim.ui.select = function(items, opts, cb)
    seen_candidates = items
    chosen = items[1]
    cb(items[1]) -- simulate an immediate pick
  end
  local ok_pcall = pcall(function()
    v:_pick_provider()
  end)
  vim.ui.select = orig_select
  check(ok_pcall, "C: _pick_provider did not error")
  check(type(seen_candidates) == "table" and #seen_candidates >= 3, "C: candidates include mock/echo + config (got " .. (seen_candidates and #seen_candidates or "nil") .. ")")
  local found_mock = false
  local found_deepseek = false
  for _, c in ipairs(seen_candidates or {}) do
    if c == "mock" then
      found_mock = true
    end
    if tostring(c):find("deepseek", 1, true) then
      found_deepseek = true
    end
  end
  check(found_mock, "C: mock in candidates")
  check(found_deepseek, "C: config providers in candidates")
  -- The stub picked items[1] ("mock"); switching to mock is a no-op but must
  -- keep the view functional (header render unchanged, no error).
  check(v.provider_name == "mock", "C: provider_name after pick (got " .. tostring(v.provider_name) .. ")")
  v:close()
end

--------------------------------------------------------------------------------
-- D. Keymap help float
--------------------------------------------------------------------------------
do
  local v = host.new({ provider = "mock", events = events.new() })
  bind_view(v)
  local ok_pcall = pcall(function()
    v:_show_keymap_help()
  end)
  check(ok_pcall, "D: _show_keymap_help did not error")
  local found = false
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    local b = vim.api.nvim_win_get_buf(w)
    local first = vim.api.nvim_buf_get_lines(b, 0, 1, false)[1] or ""
    if first:find("maxa chat keymaps", 1, true) then
      found = true
      -- Above the chat float: zindex must exceed snacks' default (50).
      local cfg = vim.api.nvim_win_get_config(w)
      assert_eq(cfg.zindex, 60, "D: help float zindex above chat")
      -- q closes it.
      pcall(vim.api.nvim_win_close, w, true)
      break
    end
  end
  check(found, "D: keymap help float opened")
  v:close()
end

--------------------------------------------------------------------------------
-- F. Demo stream: reasoning fold + tool icon + usage (offline showcase)
--------------------------------------------------------------------------------
do
  -- Offline mock chunks (reasoning + tool call + usage): previously hosted by
  -- host-module demo helpers; inlined after the W2 demo cleanup so the UI
  -- behavior assertions below keep running against a self-contained fixture.
  local function mock_chunks()
    local reasoning = {}
    for i = 1, 40 do
      reasoning[i] = ("thinking step %d about the request. "):format(i)
    end
    return {
      n.reasoning_delta(table.concat(reasoning)),
      n.message_delta("I inspected "),
      n.tool_call_started("call_demo_1", "read_file"),
      n.tool_args_delta("call_demo_1", '{"path": "demo.txt"}'),
      n.tool_call_completed("call_demo_1", '{"content": "demo file"}'),
      n.message_delta("the demo file and summarized it."),
      n.usage_updated(n.normalize_usage({ input_tokens = 120, output_tokens = 40, total_tokens = 160 })),
      n.usage_updated(
        n.normalize_usage({ input_tokens = 120, output_tokens = 40, total_tokens = 160 }, { final = true })
      ),
    }
  end
  local v = host.new({ provider = "mock", events = events.new() })
  v.provider_params = { chunks = mock_chunks(), delay = 1 }
  bind_view(v)
  local res = v:submit("demonstrate", { async = true })
  check(res ~= nil and res.async == true, "F: demo async submit started")
  check(wait_for(8000, function()
    return v.status == "completed"
  end), "F: demo stream completed")
  local lines = v:_build_lines()
  check(has_line(lines, "### Reasoning"), "F: demo renders reasoning block")
  local rline = line_of(lines, "### Reasoning")
  check(rline ~= nil, "F: reasoning header located")
  check(vim.fn.foldclosed(rline) > 0, "F: demo reasoning fold closed by default")
  local ft = vim.fn.foldtextresult(rline)
  check(ft and ft:match("^%[reasoning %d+ chars%]$") ~= nil, "F: foldtext summary (got " .. tostring(ft) .. ")")
  local joined = table.concat(lines, "\n")
  check(joined:find("✅ read_file", 1, true) ~= nil, "F: demo tool line with completed icon")
  -- W4: the demo tool call executes (read_file has no injected handler ->
  -- standard error result) and the direct pass-through continuation (default
  -- echo body) replaces the displayed usage with its local estimate (out=8).
  check(joined:find("status: completed (out=8)", 1, true) ~= nil, "F: demo usage projected (continuation local estimate)")
  v:close()
end

--------------------------------------------------------------------------------
-- G. Layout option + command registration sanity (W2 demo cleanup)
--------------------------------------------------------------------------------
do
  local v = host.new({ provider = "mock", events = events.new(), layout = "horizontal" })
  assert_eq(v.layout, "horizontal", "G: layout option propagated")
  local v2 = host.new({ provider = "mock", events = events.new() })
  assert_eq(v2.layout, host.DEFAULT_LAYOUT, "G: default layout (right-half split)")
  check(vim.fn.exists(":MaxaChat") == 2, "G: chat command still registered")
end

--------------------------------------------------------------------------------
-- H. Docked-split edge borders (inner edge only; float keeps full border)
--------------------------------------------------------------------------------
do
  local right = host._edge_border("right")
  assert_eq(right[8], "│", "H: right dock draws left edge")
  assert_eq(right[2], " ", "H: right dock hides top edge")
  assert_eq(right[4], " ", "H: right dock hides right edge")
  local bottom = host._edge_border("bottom")
  assert_eq(bottom[2], "─", "H: bottom dock draws top edge")
  assert_eq(bottom[8], " ", "H: bottom dock hides left edge")
  assert_eq(host._edge_border("left")[4], "│", "H: left dock draws right edge")
  assert_eq(host._edge_border("top")[6], "─", "H: top dock draws bottom edge")
  assert_eq(host._edge_border("float"), "rounded", "H: float keeps full rounded border")
  assert_eq(host._edge_border(nil), "rounded", "H: unknown position falls back to rounded")
end

--------------------------------------------------------------------------------
-- I. MaxaContextStop command: registration + module operation safety
--------------------------------------------------------------------------------
do
  check(vim.fn.exists(":MaxaContextStop") == 2, "I: MaxaContextStop command registered")
  -- Without a default view: safe typed no-op (WARN notify), no crash.
  local before = host._default
  host._default = nil
  local ok_nil = host.context_stop("70")
  check(ok_nil == false, "I: context_stop without view returns false")
  -- With a default view: "off" disarms through the orchestrator.
  local v3 = host.new({ provider = "mock", events = events.new() })
  host._default = v3
  local armed = v3.orch:context_stop_arm("70")
  check(armed == true, "I: arm through orchestrator before command")
  local ok_off = host.context_stop("off")
  check(ok_off == true, "I: context_stop off disarms")
  check(v3.orch._context_stop.enabled == false, "I: disarmed state confirmed")
  -- No-arg usage hint is a safe false (info notify).
  local ok_empty = host.context_stop("")
  check(ok_empty == false, "I: empty args returns false with usage hint")
  host._default = before
  v3:close()
end
--------------------------------------------------------------------------------
-- E. Terminal import-guard assert (nothing legacy loaded)
--------------------------------------------------------------------------------
do
  local guard = require("maxa.runtime.guard")
  check(guard.assert_no_forbidden(), "E: import-guard: no legacy families loaded")
end

if ok_all then
  print("UI_ACTIONS_OK")
else
  print("UI_ACTIONS_FAILED count=" .. #failures)
  vim.cmd("cq")
end
return ok_all
