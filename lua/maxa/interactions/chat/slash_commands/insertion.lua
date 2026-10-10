local M = {}

local api = vim.api
local NS_ANCHOR = api.nvim_create_namespace("maxa-ai-slash-command-anchor")

local function valid_anchor(bufnr, anchor)
  if type(anchor) ~= "table" or type(anchor.row) ~= "number" or type(anchor.col) ~= "number" then
    return nil
  end
  if anchor.row < 0 or anchor.col < 0 or anchor.row >= api.nvim_buf_line_count(bufnr) then
    return nil
  end
  local line = api.nvim_buf_get_lines(bufnr, anchor.row, anchor.row + 1, false)[1]
  if type(line) ~= "string" or anchor.col > #line then
    return nil
  end
  return { row = anchor.row, col = anchor.col }
end

local function valid_chat_anchor(chat, anchor)
  anchor = valid_anchor(chat.bufnr, anchor)
  if not anchor then
    return nil
  end
  if tonumber(chat.header_line) and anchor.row < chat.header_line then
    return nil
  end
  return anchor
end

---@param bufnr integer
---@param anchor MaxaAI.SlashCommandAnchor
---@return integer|nil
function M.track_anchor(bufnr, anchor)
  anchor = api.nvim_buf_is_valid(bufnr) and valid_anchor(bufnr, anchor) or nil
  if not anchor then
    return nil
  end
  return api.nvim_buf_set_extmark(bufnr, NS_ANCHOR, anchor.row, anchor.col, {
    right_gravity = false,
  })
end

---@param chat MaxaAI.Chat
---@param context? table
---@return integer|nil
function M.track_context(chat, context)
  if not (chat and context and context.slash_anchor and api.nvim_buf_is_valid(chat.bufnr)) then
    return nil
  end
  M.discard_anchor(chat, context)
  context.slash_anchor_extmark = M.track_anchor(chat.bufnr, context.slash_anchor)
  return context.slash_anchor_extmark
end

---@param chat MaxaAI.Chat
---@param context? table
function M.discard_anchor(chat, context)
  if chat and context and context.slash_anchor_extmark and api.nvim_buf_is_valid(chat.bufnr) then
    pcall(api.nvim_buf_del_extmark, chat.bufnr, NS_ANCHOR, context.slash_anchor_extmark)
    context.slash_anchor_extmark = nil
  end
end

---@param chat MaxaAI.Chat
---@param context? table
---@return { row: integer, col: integer }|nil
function M.resolve_anchor(chat, context)
  if not chat or type(chat.bufnr) ~= "number" or not api.nvim_buf_is_valid(chat.bufnr) then
    return nil
  end

  if context and context.slash_anchor_extmark then
    local tracked = api.nvim_buf_get_extmark_by_id(chat.bufnr, NS_ANCHOR, context.slash_anchor_extmark, {})
    if type(tracked) == "table" and #tracked == 2 then
      local anchor = valid_chat_anchor(chat, { row = tracked[1], col = tracked[2] })
      pcall(api.nvim_buf_del_extmark, chat.bufnr, NS_ANCHOR, context.slash_anchor_extmark)
      context.slash_anchor_extmark = nil
      if anchor then
        return anchor
      end
    end
  end

  local anchor = valid_chat_anchor(chat, context and context.slash_anchor)
  if anchor then
    return anchor
  end

  local window = chat.ui and chat.ui.winnr
  if not (window and api.nvim_win_is_valid(window) and api.nvim_win_get_buf(window) == chat.bufnr) then
    window = vim.iter(vim.fn.win_findbuf(chat.bufnr) or {}):find(function(win)
      return api.nvim_win_is_valid(win)
    end)
  end
  if window then
    local cursor = api.nvim_win_get_cursor(window)
    return valid_chat_anchor(chat, { row = cursor[1] - 1, col = cursor[2] })
  end
end

---@param chat MaxaAI.Chat
---@param context? table
---@param data table
---@param opts? table
---@return number|nil, number|nil, table|nil
function M.add(chat, context, data, opts)
  opts = vim.deepcopy(opts or {})
  opts.insert_at = opts.insert_at or M.resolve_anchor(chat, context)
  local last_line, icon_id, write_range = chat:add_buf_message(data, opts)
  if context and write_range and write_range["end"] then
    context.slash_anchor = vim.deepcopy(write_range["end"])
  end
  return last_line, icon_id, write_range
end

---Resolve the shared layout for ordinary and snippet Markdown prompts.
function M.prompt_position(chat, context, position)
  position = position or "inline"
  local anchor = M.resolve_anchor(chat, context)
  if not anchor then return nil end
  local line = api.nvim_buf_get_lines(chat.bufnr, anchor.row, anchor.row + 1, false)[1]
  local prefix, suffix = "", ""
  if position == "split" then
    prefix = anchor.col > 0 and "\n" or ""
    suffix = anchor.col < #line and "\n" or ""
  elseif position == "next_line" then
    anchor.col = #line
    prefix = "\n"
  elseif position == "append" then
    anchor.row = api.nvim_buf_line_count(chat.bufnr) - 1
    line = api.nvim_buf_get_lines(chat.bufnr, anchor.row, anchor.row + 1, false)[1]
    anchor.col = #line
    prefix = line ~= "" and "\n" or ""
  elseif position ~= "inline" then
    return nil
  end
  return anchor, prefix, suffix
end

---Insert user-only Markdown content inside the editable draft.
function M.add_prompt(chat, context, content, position)
  local anchor, prefix, suffix = M.prompt_position(chat, context, position)
  if not anchor then return nil end
  local result = M.add(chat, context, { role = "user", content = prefix .. content .. suffix }, { insert_at = anchor })
  if result and suffix ~= "" and chat.ui and chat.ui.winnr and api.nvim_win_is_valid(chat.ui.winnr) then
    local lines = vim.split(prefix .. content, "\n", { plain = true })
    local col = #lines == 1 and anchor.col + #lines[1] or #lines[#lines]
    api.nvim_win_set_cursor(chat.ui.winnr, { anchor.row + #lines, col })
  end
  return result
end

return M
