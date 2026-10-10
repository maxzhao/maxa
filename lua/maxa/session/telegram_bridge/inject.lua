local client = require("maxa.session.telegram_bridge.client")
local status = require("maxa.session.telegram_bridge.status")

local api = vim.api

local M = {}

local restore_callbacks = {
  "on_ready",
  "on_completed",
  "on_cancelled",
}

local function find_chat(project_root, save_id)
  local ok, maxa_ai = pcall(require, "maxa")
  if not ok or type(maxa_ai.buf_get_chat) ~= "function" then
    return nil
  end
  local ok_chats, chats = pcall(maxa_ai.buf_get_chat)
  if not ok_chats or type(chats) ~= "table" then
    return nil
  end
  for _, item in pairs(chats) do
    local chat = item.chat or item
    local payload = status.chat_payload(chat)
    if payload and payload.project_root == project_root and payload.save_id == save_id then
      return chat
    end
  end
  return nil
end

local function valid_buf(bufnr)
  return type(bufnr) == "number" and api.nvim_buf_is_valid(bufnr)
end

local function editable_range(chat)
  if not valid_buf(chat.bufnr) then
    return nil, nil
  end
  local start_line = math.max((tonumber(chat.header_line) or 1) + 2, 1)
  local line_count = api.nvim_buf_line_count(chat.bufnr)
  return math.min(start_line, line_count + 1), line_count
end

local function editable_lines(chat)
  local start_line, end_line = editable_range(chat)
  if not start_line or start_line > end_line then
    return start_line, end_line, {}
  end
  return start_line, end_line, api.nvim_buf_get_lines(chat.bufnr, start_line - 1, end_line, false)
end

function M.get_draft(chat)
  local _, _, lines = editable_lines(chat)
  return lines
end

function M.set_draft(chat, lines)
  local start_line, end_line = editable_range(chat)
  if not start_line then
    return false
  end
  lines = lines or {}
  local was_modifiable = vim.bo[chat.bufnr].modifiable
  if chat.ui and type(chat.ui.unlock_buf) == "function" then
    chat.ui:unlock_buf()
  else
    vim.bo[chat.bufnr].modifiable = true
  end
  local ok = pcall(api.nvim_buf_set_lines, chat.bufnr, start_line - 1, end_line, false, lines)
  if chat.ui and type(chat.ui.lock_buf) == "function" and not was_modifiable then
    chat.ui:lock_buf()
  elseif not was_modifiable then
    vim.bo[chat.bufnr].modifiable = false
  end
  return ok
end

local function with_chat_window(chat, fn)
  local current_win = api.nvim_get_current_win()
  local switched = false
  if valid_buf(chat.bufnr) then
    for _, win in ipairs(vim.fn.win_findbuf(chat.bufnr)) do
      if api.nvim_win_is_valid(win) then
        pcall(api.nvim_set_current_win, win)
        switched = true
        break
      end
    end
  end

  local ok, result = pcall(fn)
  if switched and api.nvim_win_is_valid(current_win) then
    pcall(api.nvim_set_current_win, current_win)
  end
  if not ok then
    return false, result
  end
  return true, result
end

function M.submit_like_chat_ui(chat)
  local ok, submitted = with_chat_window(chat, function()
    if type(chat.submit) ~= "function" then
      return false
    end
    chat:submit({ auto_submit = true })
    return chat.current_request ~= nil
  end)
  return ok and submitted == true
end

local function text_lines(text)
  return vim.split(text or "", "\n", { plain = true, trimempty = false })
end

local function user_role()
  local ok, cc_config = pcall(require, "maxa.config")
  return ok and cc_config.constants and cc_config.constants.USER_ROLE or "user"
end

local function mark_telegram_origin(chat, event, before_count)
  local messages = type(chat) == "table" and chat.messages or nil
  if type(messages) ~= "table" then
    return false
  end
  local role = user_role()
  local marked = false
  for i = (tonumber(before_count) or 0) + 1, #messages do
    local msg = messages[i]
    if type(msg) == "table" and msg.role == role then
      msg._meta = type(msg._meta) == "table" and msg._meta or {}
      msg._meta.telegram_bridge_origin = true
      msg._meta.telegram_message_id = event.telegram_message_id
      msg._meta.telegram_topic_id = event.topic_id
      marked = true
    end
  end
  return marked
end

local function chat_is_busy(chat)
  if type(chat) ~= "table" then
    return false
  end
  if chat.current_request ~= nil then
    return true
  end
  if chat.current_tool ~= nil then
    return true
  end
  if (tonumber(chat._maxa_watchdog_retry_count) or 0) > 0 then
    return true
  end
  local ok_watchdog, watchdog = pcall(require, "maxa.lifecycle.chat_request_watchdog")
  if ok_watchdog and type(watchdog.is_active) == "function" and watchdog.is_active(chat) then
    return true
  end
  return false
end

local function restore_draft_once(chat, draft, force)
  if chat._telegram_bridge_restore_pending == nil then
    chat._telegram_bridge_restore_pending = true
  end
  if chat._telegram_bridge_restore_pending == false then
    return
  end
  chat._telegram_bridge_restore_pending = false
  if not valid_buf(chat.bufnr) then
    return
  end
  local current = M.get_draft(chat)
  if force or #current == 0 or (#current == 1 and current[1] == "") then
    M.set_draft(chat, draft)
  end
end

function M.inject_into_input(chat, text)
  local draft = M.get_draft(chat)
  chat._telegram_bridge_saved_draft = draft
  chat._telegram_bridge_restore_pending = true
  local generation = (chat._telegram_bridge_draft_generation or 0) + 1
  chat._telegram_bridge_draft_generation = generation

  local restored = false
  local function restore(force)
    if restored or chat._telegram_bridge_draft_generation ~= generation then
      return
    end
    restored = true
    restore_draft_once(chat, draft, force)
  end

  if type(chat.add_callback) == "function" then
    for _, event in ipairs(restore_callbacks) do
      chat:add_callback(event, function()
        restore(false)
      end)
    end
  end

  if not M.set_draft(chat, text_lines(text)) then
    restore(true)
    return false, "draft_replace_failed"
  end
  return true, nil, function()
    restore(true)
  end
end

function M.inject_event(event, cb)
  local function reject(reason, text)
    client.event_result(event.event_id, {
      ok = false, status = reason, message = text,
      topic_id = event.topic_id, reply_to_message_id = event.telegram_message_id,
    })
    client.ack(event.event_id, function(ack_ok)
      if cb then cb(false, ack_ok and reason or 'ack_failed') end
    end)
  end

  if event.type ~= 'telegram_user_message' then
    reject('unsupported_event', '不支持的 Telegram 会话操作。')
    return
  end
  local chat = find_chat(event.project_root, event.save_id)
  local bufnr = chat and tonumber(chat.bufnr)
  local ok_ai, maxa_ai = pcall(require, 'maxa')
  local live = ok_ai and type(maxa_ai.buf_get_chat) == 'function' and valid_buf(bufnr)
  if live then
    local ok_chat, current = pcall(maxa_ai.buf_get_chat, bufnr)
    live = ok_chat and current == chat
  end
  if not live then
    reject('chat_not_open', '目标 Chat 已关闭；本条 Telegram 消息未提交。')
    return
  end
  local ok_notify, notify = pcall(require, 'maxa.session.notify_when_done')
  if not ok_notify or type(notify.is_active) ~= 'function' or not notify.is_active(chat) then
    reject('not_listening', '当前 Chat 未开启 notify 监听；本条消息未提交。')
    return
  end
  if chat_is_busy(chat) then
    reject('chat_running', 'Chat 正在运行；本条消息未提交，请在本轮结束后重发。')
    return
  end


  local ok, err, restore = M.inject_into_input(chat, event.text or "")
  if not ok then
    reject("inject_failed", "Telegram 消息注入失败；本条消息未提交。")
    return
  end

  local before_count = type(chat.messages) == "table" and #chat.messages or 0
  chat._telegram_bridge_pending_origin = {
    before_count = before_count,
    telegram_message_id = event.telegram_message_id,
    telegram_topic_id = event.topic_id,
  }
  local submitted = M.submit_like_chat_ui(chat)
  if not submitted then
    chat._telegram_bridge_pending_origin = nil
    if restore then restore() end
    reject("submit_failed", "Telegram 消息提交到 Chat 失败；本条消息未提交。")
    return
  end

  mark_telegram_origin(chat, event, before_count)
  chat._telegram_bridge_pending_origin = nil
  if type(notify.note_telegram_input) == "function" then
    notify.note_telegram_input(chat)
  end
  chat._telegram_bridge_active_request = {
    started_at = os.time(),
    event_id = event.event_id,
    telegram_message_id = event.telegram_message_id,
    topic_id = event.topic_id,
  }

  client.ack(event.event_id, function(ack_ok)
    if cb then cb(ack_ok, ack_ok and nil or "ack_failed") end
  end)

  local ok_hooks, hooks = pcall(require, "maxa.session.telegram_bridge.hooks")
  if ok_hooks and type(hooks.heartbeat) == "function" then
    hooks.heartbeat()
  end
end

M._chat_is_busy = chat_is_busy

return M
