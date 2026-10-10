-- notify_when_done: persistent Telegram notification listener for a Maxa AI chat.
--
-- Chat listener state is runtime-only and chat-local; its default is persisted per
-- Neovim configuration (not per project). Each terminal turn is notified only when
-- the chat is not observably foreground; the listener stays active until disabled/closed.
-- Notifications are delivered directly through the Lua Telegram Bridge client.

local cc_config = require("maxa.config")
local log = require("maxa.utils.log")

local STATE_KEY = "_notify_when_done_state"
local DEFAULT_APPLIED_KEY = "_notify_when_done_default_applied"
local REPLY_HINT = "\n\n💬 可回复此消息或在本主题发送普通消息；仅在 Chat 空闲且监听开启时接收。"
local LOCAL_WON_NOTICE = "\n\n⏳ 已在 Chat 端继续；上一轮回复机会已结束，请等待本轮完成通知。"
local effective_default = false
local setup_augroup

local function default_path()
  return vim.fs.joinpath(vim.fn.stdpath("state"), "maxa-ai", "notify_when_done_default")
end

local function read_saved_default()
  local path = default_path()
  if vim.fn.filereadable(path) == 0 then
    return nil
  end
  local ok, lines = pcall(vim.fn.readfile, path)
  if ok and type(lines) == "table" and #lines == 1 then
    if lines[1] == "true" then
      return true
    elseif lines[1] == "false" then
      return false
    end
  end
  vim.notify("[notify_when_done] 无效的默认监听状态: " .. path, vim.log.levels.WARN)
  return nil
end

local function save_default(enabled)
  local path = default_path()
  local dir = vim.fs.dirname(path)
  local ok, result = pcall(vim.fn.mkdir, dir, "p")
  if not ok or vim.fn.isdirectory(dir) ~= 1 then
    return false, tostring(result)
  end
  local tmp = path .. ".tmp." .. tostring(vim.uv.hrtime())
  ok, result = pcall(vim.fn.writefile, { enabled and "true" or "false" }, tmp)
  if not ok or result ~= 0 then
    pcall(vim.fn.delete, tmp)
    return false, tostring(result)
  end
  local renamed, err = vim.uv.fs_rename(tmp, path)
  if not renamed then
    pcall(vim.fn.delete, tmp)
    return false, tostring(err)
  end
  return true
end

---@class NotifyWhenDoneState
---@field active boolean
---@field callbacks_registered boolean
---@field completion_count number
---@field notified_stop boolean|nil
---@field enable_generation number

---@param chat table
---@return NotifyWhenDoneState|nil
local function get_state(chat)
  return chat and chat[STATE_KEY]
end

---@param chat table
---@return NotifyWhenDoneState
local function ensure_state(chat)
  local state = get_state(chat)
  if not state then
    state = {
      active = false,
      callbacks_registered = false,
      completion_count = 0,
      notified_stop = nil,
      enable_generation = 0,
    }
    chat[STATE_KEY] = state
  end
  return state
end

local function refresh_statusline()
  vim.schedule(function()
    local ok, status_state = pcall(require, "maxa.session.status.state")
    if ok and type(status_state.refresh) == "function" then
      status_state.refresh()
      return
    end
    pcall(vim.cmd, "redrawstatus!")
  end)
end

---@param chat table
local function deactivate_runtime(chat)
  local state = get_state(chat)
  if state then
    state.active = false
    state.notified_stop = nil
    state.reply_notice = nil
    state.enable_generation = (tonumber(state.enable_generation) or 0) + 1
  end
  refresh_statusline()
end

---@param chat table
---@param generation number
---@return boolean
local function decision_is_active(chat, generation)
  local state = get_state(chat)
  return state ~= nil
    and state.active == true
    and (tonumber(state.enable_generation) or 0) == generation
end

---@param chat table
---@return boolean
local function chat_buffer_is_foreground(chat)
  local bufnr = chat and tonumber(chat.bufnr)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return false
  end
  local ok, wins = pcall(vim.api.nvim_tabpage_list_wins, 0)
  if not ok or type(wins) ~= "table" then
    return false
  end
  for _, win in ipairs(wins) do
    if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == bufnr then
      return true
    end
  end
  return false
end

---@param args string[]
---@param callback fun(ok: boolean, stdout: string)
local function run_tmux(args, callback)
  local cmd = { "tmux" }
  vim.list_extend(cmd, args)
  local ok = pcall(vim.system, cmd, { text = true, timeout = 5000 }, function(result)
    vim.schedule(function()
      if type(result) ~= "table" or result.code ~= 0 then
        callback(false, "")
        return
      end
      callback(true, type(result.stdout) == "string" and result.stdout or "")
    end)
  end)
  if not ok then
    vim.schedule(function()
      callback(false, "")
    end)
  end
end

---@param chat table
---@param generation number
---@param callback fun(observed: boolean)
local function check_observed(chat, generation, callback)
  if not chat_buffer_is_foreground(chat) then
    callback(false)
    return
  end

  local tmux = vim.env.TMUX
  local pane = vim.env.TMUX_PANE
  local has_tmux = type(tmux) == "string" and tmux ~= ""
  local has_pane = type(pane) == "string" and pane ~= ""
  if not has_tmux and not has_pane then
    callback(true)
    return
  end
  if not has_tmux or not has_pane then
    callback(false)
    return
  end

  run_tmux({ "display-message", "-p", "-t", pane, "#{window_id}" }, function(window_ok, output)
    if not decision_is_active(chat, generation) then
      return
    end
    local window_id = vim.trim(output)
    if not window_ok or not window_id:match("^@%d+$") then
      callback(false)
      return
    end
    if not chat_buffer_is_foreground(chat) then
      callback(false)
      return
    end

    run_tmux({ "list-clients", "-F", "#{window_id}" }, function(clients_ok, clients_output)
      if not decision_is_active(chat, generation) then
        return
      end
      if not chat_buffer_is_foreground(chat) or not clients_ok then
        callback(false)
        return
      end
      for client_window_id in clients_output:gmatch("[^\r\n]+") do
        if vim.trim(client_window_id) == window_id then
          callback(true)
          return
        end
      end
      callback(false)
    end)
  end)
end

---@param value any
---@param out string[]
local function collect_text(value, out)
  if type(value) == "string" then
    if vim.trim(value) ~= "" then
      table.insert(out, value)
    end
    return
  end

  if type(value) ~= "table" then
    return
  end

  if type(value.text) == "string" then
    collect_text(value.text, out)
  end
  if type(value.content) == "string" then
    collect_text(value.content, out)
  elseif type(value.content) == "table" then
    collect_text(value.content, out)
  end

  -- Some adapters store multimodal/content parts as array-like tables.
  for _, item in ipairs(value) do
    collect_text(item, out)
  end
end

---@param content any
---@return string
local function content_to_text(content)
  local parts = {}
  collect_text(content, parts)
  return table.concat(parts, "\n")
end

---@param chat table
---@return string|nil
local function latest_llm_text(chat)
  local messages = chat and chat.messages
  if type(messages) ~= "table" or #messages == 0 then
    return nil
  end

  for i = #messages, 1, -1 do
    local msg = messages[i]
    if type(msg) == "table" and msg.role == cc_config.constants.LLM_ROLE then
      local text = content_to_text(msg.content)
      if text ~= "" then
        return text
      end
    end
  end

  return nil
end

---@param chat table
---@param status string
---@param body? string
---@return string
local function build_message(chat, status, body)
  local title = "✅ [Maxa] 当前会话本轮已结束"
  if status == "cancelled" then
    title = "⏹️ [Maxa] 当前会话本轮已停止"
  elseif status == "error" then
    title = "⚠️ [Maxa] 当前会话本轮已结束（error）"
  end

  local chat_id = chat and chat.id and tostring(chat.id) or "unknown"
  local header = title .. "\nChat: " .. chat_id

  body = body or ""
  if body == "" then
    return header .. "\n\n最后一条 LLM 消息没有可发送的文本内容。" .. REPLY_HINT
  end

  return header .. "\n\n最后一条 LLM 消息：\n" .. body .. REPLY_HINT
end

local RETRY_DELAYS_MS = { 2000, 5000, 15000 }

-- Retry only when the request demonstrably did not reach delivery. A timeout
-- or HTTP 500 may have sent to Telegram before failing; repeating it duplicates
-- the message, so surface that final error instead.
local function safe_retry_delay(decoded, result, attempt)
  if attempt > #RETRY_DELAYS_MS or type(result) ~= "table" or result.telegram_partial_delivery then
    return nil
  end
  if result.http_status == 429 then
    return math.max(RETRY_DELAYS_MS[attempt], math.min(120000, (tonumber(decoded and decoded.retry_after) or 0) * 1000))
  end
  if result.http_status == 503 and type(decoded) == "table"
    and (decoded.detail == "Telegram group topic is unavailable" or decoded.detail == "Telegram bot is unavailable") then
    return RETRY_DELAYS_MS[attempt]
  end
  if (result.http_status == nil or result.http_status == 0)
    and (result.code == 5 or result.code == 6 or result.code == 7) then
    return RETRY_DELAYS_MS[attempt]
  end
  return nil
end

---@param chat table
---@param message string
---@param still_current fun(): boolean
---@param on_exit? fun(ok: boolean, detail: string|nil, receipt: table|nil)
local function send_notify(chat, message, still_current, on_exit)
  local function send_projected(message)
  local client = require("maxa.session.telegram_bridge.client")
  local caller_context = require("maxa.session.session_identity").resolve(chat)
  local attempt = 0
  local function send()
    if not still_current() then return end
    attempt = attempt + 1
    client.notify_human_assist({ message = message, caller_context = caller_context, ask_route = true }, function(ok, decoded, result, receipt)
      if not still_current() then return end
      if ok then
        if type(receipt) == "table" then receipt.caller_context = caller_context end
        if on_exit then on_exit(true, nil, receipt) end
        return
      end
      local delay = safe_retry_delay(decoded, result, attempt)
      if delay then
        vim.defer_fn(send, delay)
        return
      end
      local detail = client.error_message(decoded, result)
      vim.notify("[notify_when_done] Telegram 通知失败: " .. detail, vim.log.levels.WARN)
      log:warn("[notify_when_done] Telegram Bridge notify failed: %s", detail)
      if on_exit then on_exit(false, detail) end
    end, still_current)
  end
  send()
  end
  require("maxa.session.file_links").transform(chat, message, send_projected)
end

local function edit_local_won(notice)
  -- This cosmetic update must never throw into Chat submission/completion hooks.
  pcall(function()
    local receipt = notice.receipt
    if type(receipt) ~= "table" or type(receipt.message_id) ~= "number"
      or type(receipt.message) ~= "string" or type(receipt.caller_context) ~= "table" then
      return
    end
    require("maxa.session.telegram_bridge.client").edit_human_assist_notification({
      message_id = receipt.message_id,
      message = receipt.message .. LOCAL_WON_NOTICE,
      caller_context = receipt.caller_context,
    })
  end)
end

---@param chat table
local function register_callbacks(chat)
  local state = get_state(chat)
  if not state or state.callbacks_registered then
    return
  end

  local function notify_terminal(self_chat, status)
    local s = get_state(self_chat)
    if not s or not s.active then
      return
    end
    s.completion_count = (s.completion_count or 0) + 1
    local completion_count = s.completion_count
    local generation = tonumber(s.enable_generation) or 0
    local body = latest_llm_text(self_chat)
    check_observed(self_chat, generation, function(observed)
      if not decision_is_active(self_chat, generation) or observed
        or s.completion_count ~= completion_count or self_chat.current_request ~= nil then
        return
      end
      local notice = { pending = true, local_won = false }
      s.reply_notice = notice
      send_notify(self_chat, build_message(self_chat, status, body), function()
        return get_state(self_chat) == s and decision_is_active(self_chat, generation)
          and s.completion_count == completion_count and s.reply_notice == notice
          and (self_chat.current_request == nil or notice.local_won)
      end, function(ok, _, receipt)
        if not ok then
          s.reply_notice = nil
          return
        end
        notice.pending = false
        notice.receipt = receipt
        if notice.local_won then
          s.reply_notice = nil
          edit_local_won(notice)
        end
      end)
    end)
  end

  state.callbacks_registered = true

  chat:add_callback("on_completed", function(self_chat, info)
    local s = get_state(self_chat)
    if not s or not s.active then
      return
    end

    local status = info and info.status or "success"
    if s.notified_stop and (status == "stopped" or status == "error") then
      s.notified_stop = nil
      return
    end

    s.notified_stop = nil
    notify_terminal(self_chat, status)
  end)

  chat:add_callback("on_cancelled", function(self_chat)
    local s = get_state(self_chat)
    if not s or not s.active then
      return
    end
    s.notified_stop = true
    notify_terminal(self_chat, "cancelled")
  end)

  chat:add_callback("on_closed", function(self_chat)
    self_chat[STATE_KEY] = nil
  end)
end

---@param chat table
local function enable_runtime(chat)
  local state = ensure_state(chat)
  state.enable_generation = (tonumber(state.enable_generation) or 0) + 1
  state.active = true
  register_callbacks(chat)
end

local M = {}

-- A normal TG submission or a local user submission consumes the most recent
-- completion notice. Programmatic continuations and @ask replies do not.
function M.note_telegram_input(chat)
  local state = get_state(chat)
  if state then
    state.reply_notice = nil
  end
end

function M.note_local_input(chat)
  local state = get_state(chat)
  local notice = state and state.active and state.reply_notice
  if not notice then
    return
  end
  if notice.pending then
    notice.local_won = true
  else
    state.reply_notice = nil
    edit_local_won(notice)
  end
end

---@param chat table|nil
---@return boolean
function M.is_active(chat)
  local state = get_state(chat)
  return state and state.active == true
end

---@param chat table|nil
---@return nil
local function refresh_bridge_heartbeat()
  local ok, hooks = pcall(require, "maxa.session.telegram_bridge.hooks")
  if ok and type(hooks.heartbeat) == "function" then
    hooks.heartbeat()
  end
end

function M.disable(chat)
  if not chat then
    return
  end
  deactivate_runtime(chat)
  refresh_bridge_heartbeat()
end

---@param chat table
---@param opts? { silent?: boolean }
local function enable_now(chat, opts)
  opts = opts or {}
  enable_runtime(chat)
  refresh_bridge_heartbeat()
  if not opts.silent then
    vim.notify("[notify_when_done] 已开启当前会话持续监听", vim.log.levels.INFO)
  end
  refresh_statusline()
end

local function resolve_chat(bufnr)
  local ok, maxa_ai = pcall(require, "maxa")
  if not ok or type(maxa_ai.buf_get_chat) ~= "function" then
    return nil
  end
  local resolved, chat = pcall(maxa_ai.buf_get_chat, bufnr)
  return resolved and type(chat) == "table" and chat or nil
end

---@param chat table|nil
---@return boolean
local function chat_is_live(chat)
  local bufnr = chat and tonumber(chat.bufnr)
  return bufnr ~= nil and vim.api.nvim_buf_is_valid(bufnr) and resolve_chat(bufnr) == chat
end

---@param chat table|nil
---@param opts? { silent?: boolean, require_live?: boolean }
---@return nil
function M.enable(chat, opts)
  opts = opts or {}
  if not chat then
    vim.notify("[notify_when_done] 当前没有可监听的 Chat", vim.log.levels.WARN)
    return
  end
  if opts.require_live and not chat_is_live(chat) then
    return
  end

  enable_now(chat, opts)
end

local function configured_default()
  local interactions = type(cc_config.interactions) == "table" and cc_config.interactions or {}
  local chat_config = type(interactions.chat) == "table" and interactions.chat or {}
  local opts = type(chat_config.opts) == "table" and chat_config.opts or {}
  return opts.notify_when_done_default == true
end

---@param chat table|nil
---@return boolean
local function is_main_agent_chat(chat)
  if type(chat) ~= "table" or chat._maxa_hidden_image_analysis or chat._is_rescue_session then
    return false
  end
  return require("maxa.session.agent_identity").is_main(chat)
end

---@return boolean
function M.default_enabled()
  return effective_default
end

---@param enabled boolean
---@param opts? { silent?: boolean }
---@return boolean
function M.set_default(enabled, opts)
  opts = opts or {}
  local desired = enabled == true
  local saved, err = save_default(desired)
  if not saved then
    vim.notify("[notify_when_done] 无法保存默认监听状态: " .. err, vim.log.levels.WARN)
    return effective_default
  end
  effective_default = desired
  if not opts.silent then
    local status = effective_default and "已启用" or "已停用"
    vim.notify("[notify_when_done] 主代理新会话默认监听" .. status, vim.log.levels.INFO)
  end
  return effective_default
end

---@return boolean
function M.toggle_default()
  return M.set_default(not effective_default)
end

function M.setup()
  if setup_augroup then
    return
  end

  local saved = read_saved_default()
  if saved == nil then
    effective_default = configured_default()
  else
    effective_default = saved
  end
  setup_augroup = vim.api.nvim_create_augroup("maxa_ai_notify_when_done_default", { clear = true })
  vim.api.nvim_create_autocmd("User", {
    group = setup_augroup,
    pattern = "MaxaAIChatSubmitted",
    callback = function(args)
      local data = type(args.data) == "table" and args.data or {}
      if data.is_user_input ~= true then
        return
      end
      local chat = resolve_chat(tonumber(data.bufnr or args.buf))
      if chat and not chat._telegram_bridge_pending_origin then
        M.note_local_input(chat)
      end
    end,
  })
  vim.api.nvim_create_autocmd("User", {
    group = setup_augroup,
    pattern = "MaxaAIChatCreated",
    callback = function(args)
      local data = type(args.data) == "table" and args.data or {}
      local bufnr = tonumber(data.bufnr or args.buf)
      if not bufnr then
        return
      end
      vim.schedule(function()
        local chat = resolve_chat(bufnr)
        if not is_main_agent_chat(chat) or chat[DEFAULT_APPLIED_KEY] then
          return
        end
        chat[DEFAULT_APPLIED_KEY] = true
        if effective_default then
          M.enable(chat, { silent = true, require_live = true })
        end
      end)
    end,
  })
end

function M.reset_setup()
  if setup_augroup then
    pcall(vim.api.nvim_del_augroup_by_id, setup_augroup)
    setup_augroup = nil
  end
  effective_default = false
end

---@param chat table|nil
---@return nil
function M.toggle(chat)
  if not chat then
    vim.notify("[notify_when_done] 当前没有可监听的 Chat", vim.log.levels.WARN)
    return
  end

  if M.is_active(chat) then
    M.disable(chat)
    vim.notify("[notify_when_done] 已取消当前会话监听", vim.log.levels.INFO)
    return
  end

  M.enable(chat)
end

return M
