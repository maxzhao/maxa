--=============================================================================
-- Functions for parsing a chat buffer using Tree-sitter
--=============================================================================
local config = require("maxa.config")
local helpers = require("maxa.interactions.chat.helpers")

local get_node_text = vim.treesitter.get_node_text --[[@type function]]
local get_query = vim.treesitter.query.get --[[@type function]]

local M = {}

---Parse the chat buffer for the last message
---@param chat MaxaAI.Chat
---@param start_range number
---@return { content: string }|nil
function M.messages(chat, start_range)
  local query = get_query("markdown", "chat")

  local tree = chat.chat_parser:parse({ start_range - 1, -1 })[1]
  local root = tree:root()

  local content = {}
  local last_role = nil

  for id, node in query:iter_captures(root, chat.bufnr, start_range - 1, -1) do
    if query.captures[id] == "role" then
      last_role = helpers.format_role(get_node_text(node, chat.bufnr))
    elseif last_role == config.interactions.chat.roles.user and query.captures[id] == "content" then
      table.insert(content, get_node_text(node, chat.bufnr))
    end
  end

  content = helpers.strip_context(content) -- If users send a blank message to the LLM, sometimes context is included
  if not vim.tbl_isempty(content) then
    return { content = vim.trim(table.concat(content, "\n\n")) }
  end

  return nil
end

---Parse the chat buffer for the last header
---@param chat MaxaAI.Chat
---@return number|nil
function M.headers(chat)
  local query = get_query("markdown", "chat")

  local tree = chat.chat_parser:parse({ 0, -1 })[1]
  local root = tree:root()

  local last_match = nil
  for id, node in query:iter_captures(root, chat.bufnr) do
    if query.captures[id] == "role_only" then
      local role = helpers.format_role(get_node_text(node, chat.bufnr))
      if role == config.interactions.chat.roles.user then
        last_match = node
      end
    end
  end

  if last_match then
    return last_match:range()
  end
end

---Parse the chat buffer for a code block
---returns the code block that the cursor is in or the last code block
---@param chat MaxaAI.Chat
---@param cursor? table
---@return TSNode|nil
function M.codeblock(chat, cursor)
  local root = chat.chat_parser:parse()[1]:root()
  local query = get_query("markdown", "chat")
  if query == nil then
    return nil
  end

  local last_match = nil
  for id, node in query:iter_captures(root, chat.bufnr, 0, -1) do
    if query.captures[id] == "code" then
      if cursor then
        local start_row, start_col, end_row, end_col = node:range()
        if cursor[1] >= start_row and cursor[1] <= end_row and cursor[2] >= start_col and cursor[2] <= end_col then
          return node
        end
      end
      last_match = node
    end
  end

  return last_match
end

return M
