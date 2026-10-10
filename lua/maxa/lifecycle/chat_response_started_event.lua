-- filepath: lua/maxa/lifecycle/chat_response_started_event.lua
-- Emit a project-scoped event when assistant content starts rendering in the chat buffer.
-- This is UI coordination only: it must not mutate messages, adapter state, or history.

local M = {}

local RESPONSE_STARTED_FLAG = "_maxa_response_started_fired"

local function is_assistant_response_message(chat, opts)
  if not chat or type(opts) ~= "table" then
    return false
  end
  local message_type = opts.type
  return message_type == chat.MESSAGE_TYPES.LLM_MESSAGE or message_type == chat.MESSAGE_TYPES.REASONING_MESSAGE
end

local function fire_response_started(chat)
  if not chat or not chat.bufnr or chat[RESPONSE_STARTED_FLAG] then
    return
  end

  chat[RESPONSE_STARTED_FLAG] = true
  vim.api.nvim_exec_autocmds("User", {
    pattern = "MaxaAIChatResponseStarted",
    data = { bufnr = chat.bufnr, id = chat.id },
  })
end

function M.reset(chat)
  if chat then
    chat[RESPONSE_STARTED_FLAG] = nil
  end
end

function M.observe(chat, opts)
  if is_assistant_response_message(chat, opts) then
    fire_response_started(chat)
  end
end

function M.setup()
  return true
end

return M
