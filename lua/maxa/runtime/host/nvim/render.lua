-- filepath: lua/maxa/runtime/host/nvim/render.lua
--- maxa host Chat renderer: incremental buffer writer + extmark decorations
--- (chat-ui-render subpackage 3.1 of .supermax/drafts/chat-ui-modernization-plan.md).
---
--- Responsibilities:
---   * `apply` converges the buffer to the full target line set with a minimal
---     prefix/suffix diff: streaming deltas append in place via
---     `nvim_buf_set_text` (previously rendered lines are never rewritten);
---     structural/state changes replace only the diverging middle range.
---   * `apply_extmarks` maintains the header/separator decorations
---     (MaxaChatHeader / MaxaChatSeparator) on top of the markdown treesitter
---     highlights owned by the view.
---   * `clear_cursor` removes the streaming-cursor virtual text placeholder.
---
--- Re-render equivalence (chat-ui spec): `apply(buf, target)` always converges
--- the buffer to exactly `target` (the view's `_build()` output), so a full
--- snapshot re-render and incremental streaming produce the same visible
--- content. Upstream alignment is semantic only (CodeCompanion v18.7.0
--- `builder.lua:264-322` incremental append / `ui/init.lua:512-582` headers +
--- virtual text); no code is copied.

local M = {}

M.name = "host.nvim.render"

-- Extmark namespaces owned by this renderer (cleared/rewritten by the view).
M.NS = vim.api.nvim_create_namespace("maxa.chat.render")
M.CURSOR_NS = vim.api.nvim_create_namespace("maxa.chat.cursor")

-- Highlight groups (linked to stable core groups; users may override later).
M.HL = {
  header = "MaxaChatHeader",
  separator = "MaxaChatSeparator",
  cursor = "MaxaChatCursor",
  tool_pending = "MaxaChatToolPending",
  tool_in_progress = "MaxaChatToolInProgress",
  tool_completed = "MaxaChatToolCompleted",
  tool_failed = "MaxaChatToolFailed",
}
-- Tool-call status -> highlight group (chat-ui-folds: state colors).
M.TOOL_HL = {
  started = M.HL.tool_pending,
  pending = M.HL.tool_pending,
  in_progress = M.HL.tool_in_progress,
  completed = M.HL.tool_completed,
  failed = M.HL.tool_failed,
}

--- Create/ensure the highlight groups (idempotent, cheap).
function M.setup_highlights()
  vim.api.nvim_set_hl(0, M.HL.header, { link = "Title", default = true })
  vim.api.nvim_set_hl(0, M.HL.separator, { link = "Comment", default = true })
  vim.api.nvim_set_hl(0, M.HL.cursor, { link = "Cursor", default = true })
  vim.api.nvim_set_hl(0, M.HL.tool_pending, { link = "DiagnosticInfo", default = true })
  vim.api.nvim_set_hl(0, M.HL.tool_in_progress, { link = "WarningMsg", default = true })
  vim.api.nvim_set_hl(0, M.HL.tool_completed, { link = "MoreMsg", default = true })
  vim.api.nvim_set_hl(0, M.HL.tool_failed, { link = "ErrorMsg", default = true })
end

--- Fold summaries: foldtext lookup table per buffer (1-based foldstart line ->
--- summary text). Populated by the view after each render; consumed by the
--- global `maxa_chat_foldtext()` used by the buffer foldtext option.
M._fold_summaries = {}

---@private Buffer-level fold expression (chat-ui-folds): `### Reasoning` opens
--- a level-1 fold; any other `### ` section header closes it. Everything else
--- keeps the previous level, so the fold spans exactly the reasoning body.
function _G.maxa_chat_foldexpr()
  local line = vim.fn.getline(vim.v.lnum)
  if line == "### Reasoning" then
    return ">1"
  end
  if line:sub(1, 4) == "### " then
    return "<1"
  end
  return "="
end

---@private Window-level foldtext: show the registered summary for the fold's
--- first line (e.g. `[reasoning 6 chars]`), otherwise the first line itself.
function _G.maxa_chat_foldtext()
  local buf = vim.api.nvim_get_current_buf()
  local map = M._fold_summaries[buf]
  local line = vim.v.foldstart
  if map and map[line] then
    return map[line]
  end
  return vim.fn.getline(line)
end

--- Bind folding to a chat buffer/window (chat-ui-folds): `foldmethod=expr` with
--- the module's foldexpr; window-local foldtext + foldlevel (folded => level 1,
--- so level-1 folds start closed; expanded => level 0, all folds open).
---@param buf integer chat buffer
---@param win integer|nil chat window
---@param opts? table { folded?: boolean }
function M.fold_bind(buf, win, opts)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  -- All fold options are window-local in Neovim (vim.wo): foldexpr,
  -- foldmethod, foldtext and foldlevel.
  M.set_foldlevel(win, not not (opts and opts.folded))
end

--- Update the window fold state. `folded` maps to foldlevel=0 (all folds
--- closed) and expanded to foldlevel=1 (level-1 folds open); Vim foldlevel
--- semantics: higher level shows more content. Idempotent; safe on invalid/
--- missing windows (no window yet => applied by fold_bind).
---@param win integer|nil
---@param folded boolean
function M.set_foldlevel(win, folded)
  if win and vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_set_option_value("foldmethod", "expr", { scope = "local", win = win })
    vim.api.nvim_set_option_value("foldexpr", "v:lua.maxa_chat_foldexpr()", { scope = "local", win = win })
    vim.api.nvim_set_option_value("foldlevel", folded and 0 or 1, { scope = "local", win = win })
    vim.api.nvim_set_option_value("foldtext", "v:lua.maxa_chat_foldtext()", { scope = "local", win = win })
    -- Visible fold markers (auto column) so collapsed blocks are discoverable;
    -- zM folds all / zR unfolds all / zo·zc work on the cursor's fold.
    vim.api.nvim_set_option_value("foldcolumn", "auto:1", { scope = "local", win = win })
  end
end

--- Register a foldtext summary for one fold-start line (1-based) of a buffer.
function M.set_fold_summary(buf, line, text)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  M._fold_summaries[buf] = M._fold_summaries[buf] or {}
  M._fold_summaries[buf][line] = text
end

--- Drop all foldtext summaries of a buffer (called before re-registering).
function M.clear_fold_summaries(buf)
  if buf then
    M._fold_summaries[buf] = nil
  end
end

--- Apply the target lines to the buffer with a minimal diff.
---
--- Classifies every render into one of:
---   "noop"    buffer already equals target
---   "append"  only the tail changed (streaming delta); no previously rendered
---             line was rewritten
---   "rewrite" a middle range was replaced (structural/state update, e.g. the
---             status footer or a tool status line)
---
--- `render_end` bounds the diff to the view's rendered region (rows 1..render_end
--- of the buffer); rows after it (the chat-ui-input integrated input area) are
--- never touched. The buffer may therefore contain more lines than `target_lines`.
---
---@param buf integer valid buffer owned by the view
---@param target_lines string[] complete target line set (from the view `_build`)
---@param stats table { appends=integer, rewrites=integer, noops=integer }
---@param render_end? integer rendered-region row count (default: whole buffer)
---@return string mode "noop"|"append"|"rewrite"
function M.apply(buf, target_lines, stats, render_end)
  if #target_lines == 0 then
    target_lines = { "" }
  end
  -- Only the rendered region participates in the diff; the input area after
  -- `render_end` rows is preserved verbatim (integrated input, chat-ui-input).
  local region_end = render_end or -1
  local current = vim.api.nvim_buf_get_lines(buf, 0, region_end, false)
  local cur_n = #current
  local tgt_n = #target_lines

  -- Common prefix: identical lines from the top.
  local prefix = 0
  while prefix < cur_n and prefix < tgt_n and current[prefix + 1] == target_lines[prefix + 1] do
    prefix = prefix + 1
  end
  -- Common suffix: identical lines from the bottom, never overlapping prefix.
  local suffix = 0
  while
    suffix < cur_n - prefix
    and suffix < tgt_n - prefix
    and current[cur_n - suffix] == target_lines[tgt_n - suffix]
  do
    suffix = suffix + 1
  end
  local cur_mid = cur_n - prefix - suffix
  local tgt_mid = tgt_n - prefix - suffix

  if cur_mid == 0 and tgt_mid == 0 then
    stats.noops = stats.noops + 1
    return "noop"
  end

  -- Initial write into an empty rendered region: classify as "rewrite", not
  -- "append" (append is reserved for streaming tail growth within one render
  -- revision; the initial full write is structural).
  if cur_n == 0 and tgt_n > 0 then
    stats.rewrites = stats.rewrites + 1
    local modifiable = vim.bo[buf].modifiable
    vim.bo[buf].modifiable = true
    local ok, err = pcall(function()
      vim.api.nvim_buf_set_lines(buf, 0, 0, false, target_lines)
    end)
    vim.bo[buf].modifiable = modifiable
    if not ok then
      error(err, 0)
    end
    return "rewrite"
  end

  -- Streaming fast path: the only difference is one line growing in place
  -- (e.g. "Hello " -> "Hello world"). `nvim_buf_set_text` appends the suffix at
  -- the end of the already-rendered line; nothing before it is rewritten.
  local in_place = false
  if cur_mid == 1 and tgt_mid == 1 then
    local cur_line = current[prefix + 1]
    local tgt_line = target_lines[prefix + 1]
    in_place = tgt_line:sub(1, #cur_line) == cur_line
  end
  local mode = "rewrite"
  if in_place or cur_mid == 0 then
    mode = "append"
  end
  if mode == "append" then
    stats.appends = stats.appends + 1
  else
    stats.rewrites = stats.rewrites + 1
  end

  local modifiable = vim.bo[buf].modifiable
  vim.bo[buf].modifiable = true
  local ok, err = pcall(function()
    if in_place then
      local cur_line = current[prefix + 1]
      local tgt_line = target_lines[prefix + 1]
      local suffix_text = tgt_line:sub(#cur_line + 1)
      vim.api.nvim_buf_set_text(buf, prefix, #cur_line, prefix, #cur_line, { suffix_text })
      return
    end
    -- General path: replace only the diverging middle range. When cur_mid == 0
    -- this is a pure append of new lines (no rendered line is touched).
    local middle = {}
    for i = 1, tgt_mid do
      middle[i] = target_lines[prefix + i]
    end
    vim.api.nvim_buf_set_lines(buf, prefix, cur_n - suffix, false, middle)
  end)
  vim.bo[buf].modifiable = modifiable
  if not ok then
    error(err, 0)
  end
  return mode
end

--- Re-apply the header/separator/tool extmarks for the rendered lines.
--- Header markers highlight the role/title line text; separator markers paint
--- the full line width (`hl_eol`) as a full-width divider; tool markers color
--- the tool status line by its current state (chat-ui-folds).
---@param buf integer valid buffer owned by the view
---@param lines string[] rendered lines (the applied target)
---@param markers table[] { line=1-based integer, kind="header"|"separator"|"tool",
---                         status?=string, id?=string }
function M.apply_extmarks(buf, lines, markers)
  vim.api.nvim_buf_clear_namespace(buf, M.NS, 0, -1)
  for _, m in ipairs(markers) do
    local row = m.line - 1
    local len = #(lines[row + 1] or "")
    if m.kind == "separator" then
      vim.api.nvim_buf_set_extmark(buf, M.NS, row, 0, {
        hl_group = M.HL.separator,
        hl_eol = true, -- full-width separator line
      })
    elseif m.kind == "tool" then
      local hl = M.TOOL_HL[m.status or "started"] or M.HL.tool_pending
      vim.api.nvim_buf_set_extmark(buf, M.NS, row, 0, {
        hl_group = hl,
        end_col = len,
      })
    else
      vim.api.nvim_buf_set_extmark(buf, M.NS, row, 0, {
        hl_group = M.HL.header,
        end_col = len,
      })
    end
  end
end

--- Clear the streaming-cursor virtual text (safe on invalid buffers).
---@param buf integer|nil
function M.clear_cursor(buf)
  if buf and vim.api.nvim_buf_is_valid(buf) then
    vim.api.nvim_buf_clear_namespace(buf, M.CURSOR_NS, 0, -1)
  end
end

return M
