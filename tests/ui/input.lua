-- filepath: tests/ui/input.lua
-- chat-ui-input headless validation (phase 1.5 subpackage 3.3):
--   A. intro placeholder virtual text: shown only while the prompt is empty,
--      never persisted into the input buffer content.
--   B. input history: submitted prompts are recorded (dedup consecutive);
--      <Up>/<Down> navigation walks the history and returns to a fresh prompt.
--   C. visual selection attach: linewise selection on the chat buffer is
--      injected into the input buffer as a fenced code block.
--   D. terminal import-guard assert (nothing legacy loaded).
--
-- Run: NVIM_APPNAME=nvim-maxa nvim --headless -c "lua vim.defer_fn(function()
--   local d='<root>/tests/ui/input.lua' local ok=pcall(dofile,d)
--   vim.cmd(ok and 'qa!' or 'cq') end, 2000)"
-- Exit 0 on success; 1 (cq) on any failed assertion.

local ok_all = true
local failures = {}

local function check(cond, msg)
  if not cond then
    ok_all = false
    failures[#failures + 1] = msg
    print("INPUT_FAIL: " .. msg)
  end
end

local function assert_eq(got, want, msg)
  if got ~= want then
    check(false, ("%s (got %s, want %s)"):format(msg, vim.inspect(got), vim.inspect(want)))
  end
end

local host = require("maxa.runtime.host.nvim")
local events = require("maxa.runtime.events")

--- Bind scratch chat + input buffers to the view (mirrors View:open's window
--- pair without the snacks layout; the chat buffer is shown in the current
--- window so visual selection works).
local function bind_view(v)
  -- Integrated input area (chat-ui-input): one modifiable chat buffer whose
  -- tail holds the input header + user content (open() semantics).
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

local function input_lines(buf)
  return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end

local function input_ns_marks(buf)
  return vim.api.nvim_buf_get_extmarks(buf, host.INPUT_NS, 0, -1, { details = true })
end

-- Input area = everything after the rendered region (header + content).
local function input_area_lines(v, buf)
  local render_end = v._render_end or 0
  return vim.api.nvim_buf_get_lines(buf, render_end, -1, false)
end

--------------------------------------------------------------------------------
-- A. Intro placeholder virtual text (integrated input area)
--------------------------------------------------------------------------------
do
  local v = host.new({ provider = "mock", events = events.new() })
  local chat = bind_view(v)
  local marks = input_ns_marks(chat)
  check(#marks >= 1, "A: intro extmark present on empty input area")
  local has_virt = false
  for _, m in ipairs(marks) do
    local det = m[4] or {}
    if det.virt_text and #det.virt_text >= 1 then
      has_virt = true
      check(det.virt_text[1][1]:find("Ask anything", 1, true) ~= nil, "A: intro text content")
    end
  end
  check(has_virt, "A: intro extmark carries virt_text")
  -- The intro sits on the first content row after the input header.
  check(input_lines(chat)[1] == host.UI.user, "A: input header is the first buffer row")
  -- Typing hides the intro (extmark cleared); content is untouched.
  vim.api.nvim_buf_set_lines(chat, 1, -1, false, { "hello" })
  v:_refresh_input_intro()
  check(#input_ns_marks(chat) == 0, "A: intro hidden when prompt non-empty")
  check(input_lines(chat)[2] == "hello", "A: prompt content unaffected by intro")
  -- Clearing restores it.
  vim.api.nvim_buf_set_lines(chat, 1, -1, false, { "" })
  v:_refresh_input_intro()
  check(#input_ns_marks(chat) >= 1, "A: intro restored after clearing")
  v:close()
end

--------------------------------------------------------------------------------
-- B. Input history: record + <Up>/<Down> navigation
--------------------------------------------------------------------------------
do
  local v = host.new({ provider = "mock", events = events.new() })
  local chat = bind_view(v)
  v:_push_input_history("first question")
  v:_push_input_history("second question")
  v:_push_input_history("second question") -- consecutive dedup
  assert_eq(#v._input_history, 2, "B: history length with dedup")

  -- Fresh input area + Up -> newest entry (header preserved, content replaced).
  v:_history_nav(-1)
  local area = input_area_lines(v, chat)
  assert_eq(area[1], host.UI.user, "B: input header preserved")
  assert_eq(area[2], "second question", "B: Up recalls newest")
  assert_eq(v._input_history_idx, 2, "B: history index after Up")

  -- Up again -> older entry.
  v:_history_nav(-1)
  assert_eq(input_area_lines(v, chat)[2], "first question", "B: Up recalls older")

  -- Down -> back to newest.
  v:_history_nav(1)
  assert_eq(input_area_lines(v, chat)[2], "second question", "B: Down recalls newer")

  -- Down past newest -> stays (index unchanged).
  v:_history_nav(1)
  assert_eq(v._input_history_idx, 2, "B: Down at newest stays")

  -- Non-empty custom prompt that is not a recalled entry: no navigation.
  vim.api.nvim_buf_set_lines(chat, 1, -1, false, { "typed manually" })
  v._input_history_idx = nil
  v:_history_nav(-1)
  assert_eq(input_area_lines(v, chat)[2], "typed manually", "B: Up ignored on custom prompt")

  -- Empty history: no navigation, no error.
  local v2 = host.new({ provider = "mock", events = events.new() })
  local chat2 = bind_view(v2)
  v2:_history_nav(-1)
  assert_eq(vim.api.nvim_buf_line_count(chat2), 2, "B: empty history leaves input area intact")
  v:close()
  v2:close()
end

--------------------------------------------------------------------------------
-- C. Visual selection attach (linewise) -> fenced code block in input
--------------------------------------------------------------------------------
do
  local v = host.new({ provider = "mock", events = events.new() })
  local chat = bind_view(v)
  -- Simulate a rendered message region (rows 1..3) above the input area.
  vim.api.nvim_buf_set_lines(chat, 0, -1, false, { "line one", "line two", "line three", host.UI.user, "" })
  v._render_end = 3
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  vim.cmd("normal! VG") -- linewise select the three message rows
  v:_attach_selection()
  local got = input_lines(chat)
  -- got = 3 message rows + header + fenced block rows
  check(got[1] == "line one", "C: message rows preserved")
  check(got[4] == host.UI.user, "C: input header after message rows")
  local joined = table.concat(got, "\n")
  check(joined:find("```text", 1, true) ~= nil, "C: fence opener present")
  check(joined:find("line three", 1, true) ~= nil, "C: selected line present")

  -- Attaching onto a non-empty input appends after a blank separator.
  vim.api.nvim_buf_set_lines(chat, 0, -1, false, { "snippet", host.UI.user, "" })
  v._render_end = 1
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  vim.cmd("normal! VG")
  v:_attach_selection()
  local got2 = input_lines(chat)
  check(got2[2] == host.UI.user, "C: input header preserved on second attach")
  local found_fence = false
  for i = 3, #got2 do
    if got2[i] == "```text" then
      found_fence = true
      break
    end
  end
  check(found_fence, "C: appended block fence present after header")
  v:close()
end

--------------------------------------------------------------------------------
-- D. Terminal import-guard assert (nothing legacy loaded)
--------------------------------------------------------------------------------
do
  local guard = require("maxa.runtime.guard")
  check(guard.assert_no_forbidden(), "D: import-guard: no legacy families loaded")
end

if ok_all then
  print("UI_INPUT_OK")
else
  print("UI_INPUT_FAILED count=" .. #failures)
  vim.cmd("cq")
end
return ok_all
