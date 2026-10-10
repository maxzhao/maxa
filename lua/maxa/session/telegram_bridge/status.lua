local billing = require("maxa.session.status.billing")
local session_identity = require("maxa.session.session_identity")
local session_status = require("maxa.session.session_status")
local token_usage = require("maxa.session.token_usage")

local M = {}

function M.save_id(chat)
  return session_identity.save_id(chat)
end

function M.chat_title(chat)
  return chat and chat.title or chat and chat.opts and chat.opts.title or nil
end

function M.current_chat()
  local ok, maxa_ai = pcall(require, "maxa")
  if not ok then
    return nil
  end
  local bufnr = vim.api.nvim_get_current_buf()
  if type(maxa_ai.buf_get_chat) == "function" then
    local ok_buf, chat = pcall(maxa_ai.buf_get_chat, bufnr)
    if ok_buf and chat then
      return chat
    end
  end
  if type(maxa_ai.last_chat) == "function" then
    local ok_last, chat = pcall(maxa_ai.last_chat)
    if ok_last then
      return chat
    end
  end
  return nil
end

function M.project_root_for_chat(chat)
  return session_identity.project_root(chat)
end

function M.chat_payload(chat)
  if type(chat) ~= "table" then
    return nil
  end
  local identity = session_identity.resolve(chat)
  if not identity then
    return nil
  end
  local project_root = identity.project_root
  local save_id = identity.save_id
  local st = session_status.from_chat(chat) or {}
  local chat_state = {
    adapter = chat.adapter,
    adapter_name = st.adapter,
    adapter_display_name = chat.adapter and (chat.adapter.formatted_name or chat.adapter.name) or st.adapter,
    model = st.model,
  }
  local usage = token_usage.get_usage(chat, chat_state)
  if usage then
    token_usage.persist_status(chat, chat_state)
  end
  local billing_parts = billing.parts(chat_state)
  local notify_active = false
  local ok_notify, notify = pcall(require, "maxa.session.notify_when_done")
  if ok_notify and type(notify.is_active) == "function" then
    notify_active = notify.is_active(chat) == true
  end
  return {
    project_root = project_root,
    save_id = save_id,
    title = st.title or M.chat_title(chat),
    adapter = st.adapter,
    adapter_display_name = chat_state.adapter_display_name,
    model = st.model,
    running = chat.current_request ~= nil,
    notify_active = notify_active,
    message_count = st.message_count,
    token_count = st.tokens,
    token_limit = st.token_limit,
    token_percent = st.token_percent or usage and usage.percent,
    balance_text = billing_parts.balance_text,
  }
end

---@param chat table|nil
---@return boolean
function M.open_chats()
  local ok, maxa_ai = pcall(require, "maxa")
  if not ok or type(maxa_ai.buf_get_chat) ~= "function" then
    return {}
  end
  local ok_chats, chats = pcall(maxa_ai.buf_get_chat)
  if not ok_chats or type(chats) ~= "table" then
    return {}
  end
  local out = {}
  for _, item in pairs(chats) do
    local chat = item
    if type(item) == "table" and item.chat then
      chat = item.chat
    end
    local payload = M.chat_payload(chat)
    if payload then
      table.insert(out, payload)
    end
  end
  return out
end

return M
