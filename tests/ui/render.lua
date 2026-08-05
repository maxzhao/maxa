-- filepath: tests/ui/render.lua
-- chat-ui-render headless validation (phase 1.5 subpackage 3.1):
--   A. sync render: re-render equivalence (buffer == _build_lines snapshot),
--      message structure (role headers + double blank line spacing), markdown
--      treesitter attach, header/separator extmarks.
--   B. streaming incremental append: N deltas -> exactly N in-place appends,
--      no rewrite during streaming, line count monotonic, same render
--      revision, final equivalence.
--   C. follow-to-bottom: default follows, pause (set_follow(false)) leaves the
--      cursor untouched while content grows, resume jumps to bottom; the
--      follow autocmd is registered on the chat buffer.
--   D. streaming virtual-text cursor: placeholder extmark while busy, never
--      persisted into buffer content, cleared after terminal.
--   E. reasoning transitions: `### Reasoning` / `### Response` headers when
--      show_reasoning=true; collapsed summary otherwise (headers hidden).
--   F. terminal import-guard assert (nothing legacy loaded).
--
-- Run: NVIM_APPNAME=nvim-maxa nvim --headless -c "lua vim.defer_fn(function()
--   local d='<root>/tests/ui/render.lua' local ok=pcall(dofile,d)
--   vim.cmd(ok and 'qa!' or 'cq') end, 2000)"
-- Exit 0 on success; 1 (cq) on any failed assertion.

local ok_all = true
local failures = {}

local function check(cond, msg)
  if not cond then
    ok_all = false
    failures[#failures + 1] = msg
    print("RENDER_FAIL: " .. msg)
  end
end

local function assert_eq(got, want, msg)
  if got ~= want then
    check(false, ("%s (got %s, want %s)"):format(msg, vim.inspect(got), vim.inspect(want)))
  end
end

local host = require("maxa.runtime.host.nvim")
local events = require("maxa.runtime.events")
local render = require("maxa.runtime.host.nvim.render")

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

--- Bind a scratch chat buffer to the view (mirrors View:open's render binding
--- without the snacks layout, so the headless run needs no UI). The buffer is
--- displayed in the current window so cursor moves (follow) are valid.
local function bind_view(v)
  -- Integrated input area (chat-ui-input): the chat buffer is modifiable and
  -- carries the input header + blank line at its tail (open() semantics).
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = true
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, buf)
  v:_bind_render_buffer(buf, win)
  v._buf = buf
  v._chat_win = win
  v._opened = true
  v:_init_input_area()
  return buf, win
end

local function buf_lines(buf)
  return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
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

local function extmark_details(buf, ns)
  return vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
end

--- Full content equivalence: the rendered region (rows 1.._render_end) must
--- equal the snapshot builder; the integrated input area follows after it.
local function check_equivalence(prefix, buf, v)
  local want = v:_build_lines()
  local got = buf_lines(buf)
  local region = v._render_end or #want
  assert_eq(region, #want, prefix .. ": render_end == snapshot rows")
  check(#got >= region, prefix .. ": buffer holds rendered region + input area (got " .. #got .. " rows)")
  local same = true
  for i = 1, region do
    if got[i] ~= want[i] then
      check(false, ("%s: rendered line %d differs (got %q, want %q)"):format(prefix, i, got[i], want[i]))
      same = false
      break
    end
  end
  check(same, prefix .. ": rendered region equals snapshot")
  -- Input area: header + blank line present after the rendered region.
  if #got > region then
    check(got[region + 1] == host.UI.user, prefix .. ": input header present (got " .. tostring(got[region + 1]) .. ")")
  end
  return got
end

local function count_hl(marks, hl_name)
  local n = 0
  for _, m in ipairs(marks) do
    if (m[4] or {}).hl_group == hl_name then
      n = n + 1
    end
  end
  return n
end

-------------------------------------------------------------------------------
-- A. Sync render: equivalence + structure + treesitter + extmarks
-------------------------------------------------------------------------------
do
  local bus = events.new()
  local v = host.new({ provider = "mock", events = bus })
  local buf = bind_view(v)
  local res = v:submit("hello")
  assert_eq(res.terminal_state, "completed", "A: sync submit terminal_state")

  local got = check_equivalence("A", buf, v)

  -- Message structure: role headers with double blank line spacing.
  local assistant_idx
  for i, l in ipairs(got) do
    if l == "Assistant" then
      assistant_idx = i
    end
  end
  check(assistant_idx ~= nil, "A: Assistant role header present")
  if assistant_idx then
    check(
      got[assistant_idx - 1] == "" and got[assistant_idx - 2] == "",
      "A: double blank line before Assistant header (idx " .. tostring(assistant_idx) .. ")"
    )
  end
  check(has_line(got, "User"), "A: User role header")
  check(has_line(got, "Hello from maxa mock/echo provider."), "A: assistant text rendered")
  check(has_line(got, "status: completed"), "A: status footer rendered")

  -- Markdown treesitter attached (parser available and queryable).
  check(v._ts_attached == true, "A: markdown treesitter parser attached (got " .. tostring(v._ts_attached) .. ")")
  local ok_parser = pcall(vim.treesitter.get_parser, buf, "markdown")
  check(ok_parser, "A: vim.treesitter.get_parser(buf, 'markdown') succeeds")

  -- Header/separator extmarks (role headers + top header + full-width divider).
  local marks = extmark_details(buf, render.NS)
  local sep = count_hl(marks, render.HL.separator)
  local hdrs = count_hl(marks, render.HL.header)
  check(sep >= 1, "A: separator extmark present (got " .. sep .. ")")
  check(hdrs >= 3, "A: header extmarks present, top+User+Assistant (got " .. hdrs .. ")")

  v:close()
end

-------------------------------------------------------------------------------
-- B. Streaming incremental append: deltas append only, no rewrite jitter
-------------------------------------------------------------------------------
do
  local chunks = {}
  for i = 1, 8 do
    chunks[i] = "chunk-" .. i .. " "
  end
  local bus = events.new()
  local v = host.new({ provider = "mock", events = bus, provider_params = { chunks = chunks, delay = 1 } })
  local buf = bind_view(v)

  -- Observed inside each message.delta dispatch (the view's handler runs
  -- first, so the stats/buffer already reflect that delta's render).
  local obs = {}
  bus.on(bus.events.message_delta or "message.delta", function()
    obs[#obs + 1] = {
      appends = v._render_stats.appends,
      rewrites = v._render_stats.rewrites,
      lines = #buf_lines(buf),
      revision = v._render_revision,
    }
  end)

  local res = v:submit("stream", { async = true })
  check(res ~= nil and res.async == true, "B: async submit started")
  check(wait_for(8000, function()
    return v.status == "completed"
  end), "B: stream reached completed (got " .. v.status .. ")")

  -- Every delta appended exactly once; streaming caused zero rewrites; the
  -- render revision stayed unchanged (same streaming revision).
  assert_eq(#obs, 8, "B: one observation per delta")
  for i, o in ipairs(obs) do
    assert_eq(o.appends, i, ("B: delta %d appended exactly once"):format(i))
    assert_eq(o.rewrites, obs[1].rewrites, ("B: delta %d caused no rewrite"):format(i))
    assert_eq(o.revision, obs[1].revision, ("B: delta %d same render revision"):format(i))
    if i > 1 then
      check(o.lines >= obs[i - 1].lines, ("B: line count monotonic at delta %d"):format(i))
    end
  end

  -- Final equivalence after incremental rendering.
  check_equivalence("B", buf, v)
  -- Only the structural renders rewrote: initial full write + request-started
  -- tail + terminal footer. Streaming itself appended only.
  check(
    v._render_stats.rewrites <= 3,
    "B: rewrites <= 3 (initial+start+terminal, got " .. v._render_stats.rewrites .. ")"
  )
  assert_eq(v._render_stats.appends, 8, "B: exactly one append per delta")

  v:close()
end

-------------------------------------------------------------------------------
-- C. Follow-to-bottom semantics
-------------------------------------------------------------------------------
do
  local bus = events.new()
  local v = host.new({ provider = "mock", events = bus })
  local buf, win = bind_view(v)

  local acmds = vim.api.nvim_get_autocmds({ buffer = buf })
  local has_follow = false
  for _, a in ipairs(acmds) do
    if a.desc == "maxa: chat follow pauses on manual scroll up" then
      has_follow = true
    end
  end
  check(has_follow, "C: follow autocmd registered on chat buffer")

  local res = v:submit("hello")
  assert_eq(res.terminal_state, "completed", "C: submit ok")
  local cur = vim.api.nvim_win_get_cursor(win)
  assert_eq(cur[1], vim.api.nvim_buf_line_count(buf), "C: follow keeps cursor at bottom after render")

  -- Paused follow: content grows but the cursor stays where the user left it.
  v:set_follow(false)
  vim.api.nvim_win_set_cursor(win, { 1, 0 })
  local res2 = v:submit("second")
  assert_eq(res2.terminal_state, "completed", "C: second submit ok")
  cur = vim.api.nvim_win_get_cursor(win)
  assert_eq(cur[1], 1, "C: cursor untouched while follow paused")
  check(cur[1] ~= vim.api.nvim_buf_line_count(buf), "C: paused follow did not force bottom")

  -- Resume: jumps back to the bottom.
  v:set_follow(true)
  cur = vim.api.nvim_win_get_cursor(win)
  assert_eq(cur[1], vim.api.nvim_buf_line_count(buf), "C: follow resume -> cursor at bottom")

  v:close()
end

-------------------------------------------------------------------------------
-- D. Streaming virtual-text cursor placeholder (not persisted into content)
-------------------------------------------------------------------------------
do
  local chunks = {}
  for i = 1, 50 do
    chunks[i] = "tick-" .. i .. " "
  end
  local bus = events.new()
  local v = host.new({ provider = "mock", events = bus, provider_params = { chunks = chunks, delay = 1 } })
  local buf = bind_view(v)

  local res = v:submit("stream", { async = true })
  check(res ~= nil and res.async == true, "D: async submit started")

  local seen_placeholder = false
  local marker_leaked = false
  local waited = 0
  while waited < 8000 and v.status ~= "completed" do
    if v.status == "busy" then
      local marks = extmark_details(buf, render.CURSOR_NS)
      if #marks >= 1 then
        seen_placeholder = true
        local virt = marks[1][4] and marks[1][4].virt_text
        check(type(virt) == "table" and #virt >= 1, "D: placeholder has virt_text")
        -- The placeholder must never be persisted into buffer content.
        local joined = table.concat(buf_lines(buf), "\n")
        if joined:find(host.UI.cursor_marker, 1, true) then
          marker_leaked = true
        end
      end
    end
    vim.wait(20)
    waited = waited + 20
  end
  check(seen_placeholder, "D: streaming placeholder appeared while busy")
  check(not marker_leaked, "D: cursor marker not persisted into buffer content")
  check(v.status == "completed", "D: stream completed (got " .. v.status .. ")")
  assert_eq(#extmark_details(buf, render.CURSOR_NS), 0, "D: placeholder cleared after terminal")

  v:close()
end

-------------------------------------------------------------------------------
-- E. Reasoning transition headers + collapsed summary
-------------------------------------------------------------------------------
do
  local n = require("maxa.runtime.protocol.normalize")
  local chunks = {
    n.reasoning_delta("think "),
    n.message_delta("Hello "),
    n.message_delta("world"),
  }

  -- Expanded (show_reasoning=true): `### Reasoning` / `### Response` headers,
  -- reasoning content visible, and the fold exists but is open.
  local bus = events.new()
  local v = host.new({ provider = "mock", events = bus, show_reasoning = true, provider_params = { chunks = chunks } })
  local buf = bind_view(v)
  local res = v:submit("use the tool")
  assert_eq(res.terminal_state, "completed", "E: expanded submit")
  local lines = check_equivalence("E", buf, v)
  check(has_line(lines, "### Reasoning"), "E: ### Reasoning header")
  check(has_line(lines, "### Response"), "E: ### Response header")
  check(has_line(lines, "think"), "E: reasoning content visible")
  check(has_line(lines, "Hello world"), "E: response text")
  local eline = line_of(lines, "### Reasoning")
  check(eline ~= nil, "E: expanded reasoning header located")
  check(vim.fn.foldclosed(eline) == -1, "E: expanded reasoning fold is open")
  v:close()

  -- Collapsed default: full reasoning rendered into the buffer, hidden by a
  -- real level-1 fold; the foldtext shows the `[reasoning N chars]` summary
  -- and zo/zc toggle interactively.
  local bus2 = events.new()
  local v2 = host.new({ provider = "mock", events = bus2, provider_params = { chunks = chunks } })
  local buf2 = bind_view(v2)
  local res2 = v2:submit("use the tool")
  assert_eq(res2.terminal_state, "completed", "E: collapsed submit")
  local lines2 = check_equivalence("E", buf2, v2)
  check(has_line(lines2, "### Reasoning"), "E: reasoning header rendered")
  check(has_line(lines2, "think"), "E: reasoning content present in buffer")
  check(has_line(lines2, "### Response"), "E: response header present")
  local rline = line_of(lines2, "### Reasoning")
  check(rline ~= nil, "E: reasoning header line located")
  check(vim.fn.foldclosed(rline) > 0, "E: reasoning fold closed by default")
  check(vim.wo[v2._chat_win].foldcolumn ~= nil and vim.wo[v2._chat_win].foldcolumn ~= "0", "E: fold column visible (got " .. tostring(vim.wo[v2._chat_win].foldcolumn) .. ")")
  local ft = vim.fn.foldtextresult(rline)
  check(ft and ft:find("[reasoning 6 chars]", 1, true) ~= nil, "E: foldtext shows summary")
  vim.api.nvim_win_set_cursor(0, { rline, 0 })
  vim.cmd("normal! zo")
  check(vim.fn.foldclosed(rline) == -1, "E: zo opens reasoning fold")
  vim.cmd("normal! zc")
  check(vim.fn.foldclosed(rline) > 0, "E: zc closes reasoning fold")
  v2:close()
end

-------------------------------------------------------------------------------
-- F. Terminal import-guard assert (nothing legacy loaded)
-------------------------------------------------------------------------------
do
  local guard = require("maxa.runtime.guard")
  check(guard.assert_no_forbidden(), "F: import-guard: no legacy families loaded")
end

if ok_all then
  print("UI_RENDER_OK")
else
  print("UI_RENDER_FAILED count=" .. #failures)
  vim.cmd("cq")
end
return ok_all
