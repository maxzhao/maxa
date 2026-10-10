local config = require("maxa.config")
local log = require("maxa.utils.log")

local api = vim.api

---@class MaxaAI.Chat.UI.Folds
local Folds = {}

local CONSTANTS = {
  NS_FOLD_TOOLS = api.nvim_create_namespace("MaxaAI-tool_fold_marks"),
  NS_FOLD_REASONING = api.nvim_create_namespace("MaxaAI-reasoning_fold_marks"),
}

-- Unified fold summaries storage
---@type table<number, table<number, { content: string, type: "tool"|"reasoning" }>>
Folds.fold_summaries = {}

-- Extmark-backed definitions survive hidden buffers; actual folds belong to windows.
local definitions = {}
local namespaces = {
  tool = CONSTANTS.NS_FOLD_TOOLS,
  reasoning = CONSTANTS.NS_FOLD_REASONING,
}

function Folds:is_chat_window(winnr, bufnr)
  return winnr and api.nvim_win_is_valid(winnr)
    and vim.fn.win_gettype(winnr) ~= "autocmd"
    and api.nvim_win_get_buf(winnr) == bufnr
end

function Folds:windows(bufnr)
  local wins = {}
  for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
    if self:is_chat_window(win, bufnr) then
      wins[#wins + 1] = win
    end
  end
  return wins
end

-- Refresh row-indexed summaries from marks, rather than retaining stale row numbers.
function Folds:_ranges(bufnr)
  local ranges = {}
  local summaries = {}
  for fold_type, entries in pairs(definitions[bufnr] or {}) do
    local ns = namespaces[fold_type]
    for id, data in pairs(entries) do
      local mark = api.nvim_buf_get_extmark_by_id(bufnr, ns, id, { details = true })
      local details = mark[3]
      if details and not details.invalid and details.end_row then
        local start_row, end_row = mark[1], details.end_row - 1
        summaries[start_row] = data
        if start_row < end_row then
          ranges[#ranges + 1] = { start_row = start_row, end_row = end_row, data = data }
        end
      else
        entries[id] = nil
        api.nvim_buf_del_extmark(bufnr, ns, id)
      end
    end
  end
  self.fold_summaries[bufnr] = summaries
  table.sort(ranges, function(a, b) return a.start_row < b.start_row end)
  return ranges
end

-- Recognize the exact innermost range at its header, even inside an outer fold.
-- Restore initially closed ancestors and the view; never select a neighboring fold.
local function exact_fold(first, last, remove, collapsed)
  local closed = {}
  while vim.fn.foldclosed(first) ~= -1 do
    local start, finish = vim.fn.foldclosed(first), vim.fn.foldclosedend(first)
    if start == first and finish == last then
      if remove then vim.fn.cursor(first, 1); vim.cmd("normal! zd")
      elseif collapsed == false then vim.cmd(first .. "foldopen") end
      for index = #closed, 1, -1 do vim.cmd(closed[index] .. "foldclose") end
      return true
    end
    closed[#closed + 1] = start
    vim.cmd(first .. "foldopen")
  end
  local exists = false
  if vim.fn.foldlevel(first) > 0 then
    vim.cmd(first .. "foldclose")
    exists = vim.fn.foldclosed(first) == first and vim.fn.foldclosedend(first) == last
    if exists and remove then vim.fn.cursor(first, 1); vim.cmd("normal! zd")
    elseif not exists or collapsed ~= true then vim.cmd(first .. "foldopen") end
  end
  for index = #closed, 1, -1 do vim.cmd(closed[index] .. "foldclose") end
  return exists
end

-- Native manual folds and logical end extmarks adjust differently at a deleted
-- last line. Reconcile an owned header, not its now-stale end: remove only folds
-- beginning exactly here, leaving nested members and enclosing owners intact.
local function remove_header_folds(first)
  local closed = {}
  while true do
    local start = vim.fn.foldclosed(first)
    if start == -1 then
      if vim.fn.foldlevel(first) == 0 then break end
      vim.cmd(first .. "foldclose")
      start = vim.fn.foldclosed(first)
      if start == -1 then break end
      if start ~= first then vim.cmd(first .. "foldopen"); break end
    end
    if start == first then
      vim.fn.cursor(first, 1)
      vim.cmd("normal! zd")
    else
      closed[#closed + 1] = start
      vim.cmd(first .. "foldopen")
    end
  end
  for index = #closed, 1, -1 do vim.cmd(closed[index] .. "foldclose") end
end

-- Ex ranges inside a closed fold expand to that entire fold. Expose both
-- requested endpoints before creation, then restore only pre-existing closures.
local function create_exact_fold(first, last)
  local closed = {}
  for _, line in ipairs({ first, last }) do
    while vim.fn.foldclosed(line) ~= -1 do
      closed[#closed + 1] = { vim.fn.foldclosed(line), vim.fn.foldclosedend(line) }
      vim.cmd(line .. "foldopen")
    end
  end
  vim.cmd(string.format("%d,%dfold", first, last))
  for index = #closed, 1, -1 do
    exact_fold(closed[index][1], closed[index][2], false, true)
  end
end

-- Count only folds starting at this owned header. Probe the containing stack
-- without deleting it; restore its original closed layers before returning.
local function header_fold_count(first)
  local closed = {}
  while vim.fn.foldclosed(first) ~= -1 do
    closed[#closed + 1] = vim.fn.foldclosed(first)
    vim.cmd(first .. "foldopen")
  end
  local count = 0
  if vim.fn.foldlevel(first) > 0 then
    vim.cmd(first .. "foldclose!")
    while vim.fn.foldclosed(first) ~= -1 do
      if vim.fn.foldclosed(first) == first then count = count + 1 end
      vim.cmd(first .. "foldopen")
    end
  end
  for index = #closed, 1, -1 do vim.cmd(closed[index] .. "foldclose") end
  return count
end

-- Apply only missing exact folds; initial/terminal policy is applied once per window.
function Folds:apply(bufnr, winnr)
  if not self:is_chat_window(winnr, bufnr) then
    return
  end
  local ranges = self:_ranges(bufnr)
  self:setup(winnr)
  local minlines = api.nvim_get_option_value("foldminlines", { win = winnr })
  local ok, err = pcall(api.nvim_win_call, winnr, function()
    local view = vim.fn.winsaveview()
    -- Tiny stale folds are otherwise invisible to foldclosed(), even though
    -- foldlevel() includes them and foldclose may select them instead of outer.
    vim.wo.foldminlines = 0
    local changed = {}
    -- Build every nested range before applying collapse transitions. Topology
    -- inspection may temporarily open an ancestor to reach a member fold.
    for _, range in ipairs(ranges) do
      local first, last = range.start_row + 1, range.end_row + 1
      -- A matching range can still hide another identical-header fold. Such a
      -- duplicate makes one foldopen succeed while leaving the batch closed.
      local expected_level = 0
      for _, containing in ipairs(ranges) do
        if containing.start_row <= range.start_row and containing.end_row >= range.start_row then
          expected_level = expected_level + 1
        end
      end
      -- Only inspect a suspicious stack. Normal member/history folds retain
      -- their open state without close-all probing on each refresh.
      local duplicate = vim.fn.foldlevel(first) > expected_level and header_fold_count(first) > 1
      local missing = duplicate or not exact_fold(first, last)
      if missing then
        remove_header_folds(first)
        create_exact_fold(first, last)
      end
      local data = range.data
      data.applied = data.applied or {}
      if missing or data.applied[winnr] ~= data.collapsed then changed[range] = true end
    end
    -- Members settle first; a running/terminal outer transition is last and is
    -- latched only after its exact range accepts the requested policy.
    for index = #ranges, 1, -1 do
      local range = ranges[index]
      if changed[range] and exact_fold(range.start_row + 1, range.end_row + 1, false, range.data.collapsed) then
        range.data.applied[winnr] = range.data.collapsed
      end
    end
    vim.fn.winrestview(view)
  end)
  api.nvim_set_option_value("foldminlines", minlines, { win = winnr })
  if not ok then
    log:trace("[Folds] Failed to apply folds in window %d: %s", winnr, err)
  end
end

---@class MaxaAI.Chat.UI.FoldConfig
---@field type "tool"|"reasoning"
---@field content string
---@field success_keywords? string[]
---@field failure_keywords? string[]

---Initialize fold settings for a buffer/window
---@param winnr number
function Folds:setup(winnr)
  if winnr and api.nvim_win_is_valid(winnr) then
    api.nvim_win_call(winnr, function()
      if vim.wo.foldmethod ~= "manual" then
        vim.wo.foldmethod = "manual"
      end
    end)
    api.nvim_set_option_value(
      "foldtext",
      'v:lua.require("maxa.interactions.chat.ui.folds").fold_text()',
      { win = winnr }
    )
  end
end

---Global method which Neovim calls to display folded text
---@return table
function Folds.fold_text()
  local bufnr = api.nvim_get_current_buf()
  local start = vim.v.foldstart - 1
  Folds:_ranges(bufnr)
  local folds = Folds.fold_summaries[bufnr] or {}
  local fold_data = folds[start]

  if not fold_data then
    -- Fallback for legacy data
    return Folds._format_fold_text("Unknown", "reasoning")
  end

  return Folds._format_fold_text(fold_data.content, fold_data.type)
end

---Format fold text based on type
---@param content string
---@param fold_type "tool"|"reasoning"
---@return table[]
function Folds._format_fold_text(content, fold_type)
  local chunks = {}

  if fold_type == "tool" then
    local summary_hl = "MaxaAIChatToolSuccess"
    local failure_words = config.interactions.chat.tools.opts.folds.failure_words or {}
    for _, word in ipairs(failure_words) do
      if content:lower():find(word) then
        summary_hl = "MaxaAIChatToolFailure"
        break
      end
    end
    -- Tool presentation already owns its status/title. Fold text must not
    -- prepend a second success/failure icon or its configured spacer.
    table.insert(chunks, { content, summary_hl })
  elseif fold_type == "reasoning" then
    table.insert(chunks, { content, "MaxaAIChatFold" })
  end

  return chunks
end

---Delete a fold exactly at the specified line, without affecting outer folds
---@param bufnr number
---@param line number  -- 0-based start line of the exact fold to remove
function Folds:_delete(bufnr, line, last)
  for _, win in ipairs(self:windows(bufnr)) do
    local minlines = api.nvim_get_option_value("foldminlines", { win = win })
    local ok, err = pcall(api.nvim_win_call, win, function()
      local view = vim.fn.winsaveview()
      vim.wo.foldminlines = 0
      remove_header_folds(line + 1)
      vim.fn.winrestview(view)
    end)
    api.nvim_set_option_value("foldminlines", minlines, { win = win })
    if not ok then
      log:trace("[Folds] Failed to delete exact fold at line %d: %s", line, err)
    end
  end
end

-- Replacements/crops invalidate every intersecting logical fold before editing.
function Folds:invalidate_range(bufnr, first, last)
  if last <= first then return end
  for fold_type, entries in pairs(definitions[bufnr] or {}) do
    local ns = namespaces[fold_type]
    for id in pairs(entries) do
      local mark = api.nvim_buf_get_extmark_by_id(bufnr, ns, id, { details = true })
      if mark[3] and mark[1] < last and mark[3].end_row > first then
        self:_delete(bufnr, mark[1], mark[3].end_row - 1)
        entries[id] = nil
        api.nvim_buf_del_extmark(bufnr, ns, id)
      end
    end
  end
  self:_ranges(bufnr)
end

---Create a new fold
---@param bufnr number
---@param start_row number (0-based)
---@param end_row number (0-based)
---@param fold_config MaxaAI.Chat.UI.FoldConfig
function Folds:_create(bufnr, start_row, end_row, fold_config)
  if not api.nvim_buf_is_valid(bufnr) or start_row > end_row then
    return
  end

  self:_ranges(bufnr)
  local fold_type = fold_config.type
  local ns = namespaces[fold_type]
  definitions[bufnr] = definitions[bufnr] or {}
  definitions[bufnr][fold_type] = definitions[bufnr][fold_type] or {}
  local entries = definitions[bufnr][fold_type]
  local mark_id, resized
  for id in pairs(entries) do
    local mark = api.nvim_buf_get_extmark_by_id(bufnr, ns, id, { details = true })
    if mark[1] == start_row then
      mark_id = id
      if mark[3].end_row ~= end_row + 1 then
        self:_delete(bufnr, start_row, mark[3].end_row - 1)
        resized = true
      end
      break
    end
  end

  local opts = {
    id = mark_id,
    end_row = end_row + 1,
    end_col = 0,
    right_gravity = true,
    end_right_gravity = false,
    invalidate = true,
  }
  mark_id = api.nvim_buf_set_extmark(bufnr, ns, start_row, 0, opts)
  local previous = entries[mark_id]
  entries[mark_id] = { content = fold_config.content, type = fold_type,
    collapsed = fold_config.collapsed ~= false,
    applied = not resized and previous and previous.applied or {} }
  self:_ranges(bufnr)
  for _, win in ipairs(self:windows(bufnr)) do
    self:apply(bufnr, win)
  end
end

---Create a fold by deleting any existing folds in the range and recreating
---@param bufnr number
---@param start_row number (0-based)
---@param end_row number (0-based)
---@param fold_config MaxaAI.Chat.UI.FoldConfig
function Folds:recreate(bufnr, start_row, end_row, fold_config)
  self:_create(bufnr, start_row, end_row, fold_config)
end

---Create a tool fold (backward compatibility method)
---@param bufnr number
---@param start_row number (0-based)
---@param end_row number (0-based)
---@param foldtext string
function Folds:create_tool_fold(bufnr, start_row, end_row, foldtext, policy)
  if not config.interactions.chat.tools.opts.folds.enabled then
    return
  end

  self:_create(bufnr, start_row, end_row, {
    type = "tool",
    content = foldtext,
    collapsed = policy and policy.collapsed,
  })
end

---Fold the most recent reasoning section in the chat buffer
---@param chat MaxaAI.Chat
---@param start_row number (0-based)
---@param end_row number (0-based)
---@return nil
function Folds:create_reasoning_fold(chat, start_row, end_row)
  if not config.display.chat.fold_reasoning then
    return
  end

  local summary_text = "  " .. config.display.chat.icons.chat_fold .. " ..."

  local bufnr = chat.bufnr
  local parser = chat.chat_parser
  if not (bufnr and parser) then
    return
  end

  local ok, query = pcall(
    vim.treesitter.query.parse,
    "markdown",
    [[
    (section
      (atx_heading
        (atx_h3_marker)
        heading_content: (_) @block_name
      )
      (#eq? @block_name "Reasoning")
    ) @reasoning
  ]]
  )
  if not ok or not query then
    return
  end

  local tree = parser:parse({ start_row, end_row })[1]
  if not tree then
    return
  end
  local root = tree:root()

  local latest_node, latest_range = nil, -1
  for id, node in query:iter_captures(root, bufnr, start_row, end_row) do
    if query.captures[id] == "reasoning" then
      local range = node:range()
      if range >= latest_range then
        latest_node, latest_range = node, range
      end
    end
  end
  if not latest_node then
    return
  end

  local range, _, er = latest_node:range()
  local fold_start = range + 1
  local fold_end = math.max(fold_start, er - 1)

  -- Don't fold if there's no content to fold
  if fold_start >= fold_end then
    return
  end

  self:recreate(bufnr, fold_start, fold_end, {
    type = "reasoning",
    content = summary_text,
  })
end

---Clean up fold data for a buffer
---@param bufnr number
function Folds:cleanup(bufnr)
  definitions[bufnr] = nil
  self.fold_summaries[bufnr] = nil
  if not api.nvim_buf_is_valid(bufnr) then
    return
  end
  for _, win in ipairs(self:windows(bufnr)) do
    api.nvim_win_call(win, function()
      if vim.wo.foldmethod == "manual" then
        vim.cmd("normal! zE")
      end
    end)
  end
  api.nvim_buf_clear_namespace(bufnr, CONSTANTS.NS_FOLD_TOOLS, 0, -1)
  api.nvim_buf_clear_namespace(bufnr, CONSTANTS.NS_FOLD_REASONING, 0, -1)
end

return Folds
