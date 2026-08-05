-- filepath: tests/tools/tool-fold.lua
--- Phase-3 W7 fixture: tool output fold headless assertion (chat-ui-folds
--- result-detail fold: `### Tool:` level-1 fold, zo/zc toggle, execution-aware
--- summary foldtext; safe when NO buffer is attached).
---   * a registry tool executes through the host view and the render contains
---     the `### Tool:` fold header + the projected result detail body,
---   * with a real (synthetic) buffer the fold is created: closed by default
---     (show_reasoning=false => foldlevel 0), the foldtext is the summary
---     line, zo opens it, zc closes it,
---   * without any buffer the view stays safe: submit / _build_lines / _render
---     do not throw and the display projection is still populated.
---
--- Fixture convention: prints TOOLS_TOOL_FOLD_OK on success; throws on failure.
local assert_mod = require("tests.state.lib.assert")
local registry_mod = require("maxa.runtime.tools.registry")
local host = require("maxa.runtime.host.nvim")
local events = require("maxa.runtime.events")
local n = require("maxa.runtime.protocol.normalize")

local A = assert_mod.new()

--- Bind a synthetic chat buffer/window to a view (same pattern as
--- tests/ui/actions.lua bind_view; headless-safe).
---@param v table view
---@return integer chat, integer win
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
  return chat, win
end

local function line_of(lines, needle)
  for i, l in ipairs(lines) do
    if l:find(needle, 1, true) then
      return i
    end
  end
  return nil
end

do
  local reg = registry_mod.new()
  reg:register({
    id = "demo/read_file",
    name = "read_file",
    description = "returns deterministic content",
    input_schema = { type = "object", properties = { path = { type = "string" } } },
    run = function(args)
      return ("content of %s\ndetail line"):format(args.path or "?")
    end,
  })
  local chunks = {
    n.tool_call_started("call_fold_1", "read_file"),
    n.tool_args_delta("call_fold_1", '{"path":"x"}'),
    n.tool_call_completed("call_fold_1", '{"path":"x"}'),
  }

  -- With a bound buffer: fold creation + zo/zc + summary foldtext.
  local v = host.new({
    provider = "mock",
    events = events.new(),
    provider_params = { chunks = chunks },
    tool_registry = reg,
  })
  bind_view(v)
  local res = v:submit("read it")
  A.assert_eq(res.terminal_state, "completed", "fold: submit completed")
  local lines = v:_build_lines()
  local hline = line_of(lines, "### Tool: read_file")
  A.check(hline ~= nil, "fold: `### Tool: read_file` header rendered")
  A.check(line_of(lines, "content of x") ~= nil, "fold: detail body projected")
  A.check(line_of(lines, "detail line") ~= nil, "fold: second detail line projected")

  -- Fold exists and is closed by default (show_reasoning=false => foldlevel 0).
  A.check(vim.fn.foldclosed(hline) > 0, "fold: tool fold closed by default")
  local ft = vim.fn.foldtextresult(hline)
  A.check(ft ~= nil and ft:match("^%[.*read_file.*%]") ~= nil, "fold: foldtext is the summary line (got " .. tostring(ft) .. ")")
  A.check(ft ~= nil and ft:find("content of x", 1, true) ~= nil, "fold: foldtext contains the projected summary")
  -- zo opens; zc closes.
  vim.api.nvim_win_set_cursor(0, { hline, 0 })
  vim.cmd("normal! zo")
  A.check(vim.fn.foldclosed(hline) == -1, "fold: zo opens the tool fold")
  vim.cmd("normal! zc")
  A.check(vim.fn.foldclosed(hline) > 0, "fold: zc closes the tool fold")
  v:close()

  -- Without any buffer: submit/build/render stay safe and the display
  -- projection is still populated (rendering is buffer-guarded).
  local v2 = host.new({
    provider = "mock",
    events = events.new(),
    provider_params = { chunks = chunks },
    tool_registry = reg,
  })
  local ok_submit, res2 = pcall(v2.submit, v2, "read it")
  A.check(ok_submit and res2 and res2.terminal_state == "completed", "fold: no-buffer submit safe")
  local ok_build, lines2 = pcall(v2._build_lines, v2)
  A.check(ok_build and type(lines2) == "table", "fold: no-buffer _build_lines safe")
  local joined = table.concat(lines2 or {}, "\n")
  A.check(joined:find("### Tool: read_file", 1, true) ~= nil, "fold: no-buffer render contains fold header")
  A.check(v2._tool_display["call_fold_1"] ~= nil, "fold: no-buffer display projection populated")
  local ok_render = pcall(v2._render, v2)
  A.check(ok_render, "fold: no-buffer _render safe (guard returns early)")
  v2:close()
end

if A.ok then
  print("TOOLS_TOOL_FOLD_OK")
else
  error("TOOLS_TOOL_FOLD_FAILED count=" .. #A.failures)
end
