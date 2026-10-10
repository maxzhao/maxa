local client = require("maxa.session.telegram_bridge.client")
local config = require("maxa.session.telegram_bridge.config")
local hooks = require("maxa.session.telegram_bridge.hooks")
local status = require("maxa.session.telegram_bridge.status")

local M = {}
local sessions = {}
local PLACEHOLDER = "请在 Telegram 中回复 Bot 发出的上传消息；可发送一个文件或纯文字。"
local exit_hook_group

local function notify(message, level)
  vim.notify("[tg_upload] " .. message, level or vim.log.levels.INFO)
end

local function busy(chat)
  return chat.current_request ~= nil or chat.current_tool ~= nil or (chat.status ~= nil and chat.status ~= "")
end

local function valid_chat(chat)
  return type(chat) == "table" and type(chat.bufnr) == "number" and vim.api.nvim_buf_is_valid(chat.bufnr)
    and type(chat.add_buf_message) == "function" and type(chat.ui) == "table"
end

local function caller(state)
  return { instance_id = state.instance_id, project_root = state.project_root, save_id = state.save_id }
end

local function request_error(decoded, result, fallback)
  if type(decoded) == "table" then
    local detail = decoded.detail or decoded.message
    if type(detail) == "table" then detail = detail.message or detail.code end
    if detail ~= nil and tostring(detail) ~= "" then return tostring(detail) end
  end
  if type(result) == "table" then
    if type(result.stderr) == "string" and result.stderr ~= "" then return result.stderr end
    if result.http_status then return "HTTP " .. tostring(result.http_status) end
    if result.code ~= nil then return "exit " .. tostring(result.code) end
  end
  return fallback
end

local function unlock(state)
  if not state.locked then return end
  state.locked = false
  if vim.api.nvim_buf_is_valid(state.bufnr) and type(state.chat.ui.unlock_buf) == "function" then
    pcall(state.chat.ui.unlock_buf, state.chat.ui)
  end
end

local function clear_hooks(state)
  if state.augroup then pcall(vim.api.nvim_del_augroup_by_id, state.augroup) end
  state.augroup = nil
  if state.retry_timer then state.retry_timer:stop(); state.retry_timer:close() end
  state.retry_timer = nil
end

local function replace_placeholder(state, lines)
  if not vim.api.nvim_buf_is_valid(state.bufnr) then return false end
  local range = state.placeholder_range
  if range then
    local got_text, current = pcall(
      vim.api.nvim_buf_get_text,
      state.bufnr,
      range.start.row,
      range.start.col,
      range["end"].row,
      range["end"].col,
      {}
    )
    if not got_text or table.concat(current, "\n") ~= PLACEHOLDER then return false end
    local ok = pcall(
      vim.api.nvim_buf_set_text,
      state.bufnr,
      range.start.row,
      range.start.col,
      range["end"].row,
      range["end"].col,
      lines or {}
    )
    if ok then state.placeholder_range = nil; state.placeholder_line = nil end
    return ok
  end

  if not state.placeholder_line then return false end
  local row = state.placeholder_line - 1
  if row < 0 or row >= vim.api.nvim_buf_line_count(state.bufnr) then return false end
  if vim.api.nvim_buf_get_lines(state.bufnr, row, row + 1, false)[1] ~= PLACEHOLDER then return false end
  local ok = pcall(vim.api.nvim_buf_set_lines, state.bufnr, row, row + 1, false, lines or {})
  if ok then state.placeholder_line = nil end
  return ok
end

local function cancel_bridge(state)
  if state.request_id and not state.cancel_sent then
    state.cancel_sent = true
    client.cancel_chat_upload(state.request_id, caller(state), function() end)
  end
end

local function finish(state, kind, detail)
  if state.finished then return false end
  state.finished = true
  sessions[state.bufnr] = nil
  clear_hooks(state)
  unlock(state)
  require("maxa.interactions.chat.slash_commands.insertion").discard_anchor(
    state.chat,
    state.insertion_context
  )
  if kind == "completed" then
    if not replace_placeholder(state, detail) then
      local content = table.concat(detail, "\n")
      local ok, err = pcall(state.chat.add_buf_message, state.chat, { content = content })
      if not ok then notify("结果插入失败: " .. tostring(err), vim.log.levels.ERROR) end
    end
  else
    replace_placeholder(state, nil)
    if kind == "error" then notify(detail, vim.log.levels.ERROR) end
  end
  return true
end

local function realpath(path)
  return vim.uv.fs_realpath(path)
end

local function path_below(path, parent)
  return path == parent or path:sub(1, #parent + 1) == parent .. "/"
end

local function valid_result(state, result)
  if type(result) ~= "table" or result.request_id ~= state.request_id or result.session_id ~= state.session_id then
    return nil, "Bridge 返回了无效请求身份"
  end
  local lines = {}
  if result.path ~= nil then
    if type(result.path) ~= "string" or result.path:sub(1, 1) == "/" or result.path:find("\\", 1, true) then return nil, "Bridge 返回了无效文件路径" end
    local prefix = ".maxa/upload/" .. state.session_id .. "/"
    local basename = result.path:sub(#prefix + 1)
    if result.path:sub(1, #prefix) ~= prefix or basename == "" or basename:find("/", 1, true) then return nil, "Bridge 返回了越界文件路径" end
    for segment in result.path:gmatch("[^/]+") do
      if segment == "." or segment == ".." or segment == "" then return nil, "Bridge 返回了越界文件路径" end
    end
    local real_root = realpath(state.project_root)
    local upload_root = vim.fs.joinpath(real_root or state.project_root, ".maxa", "upload")
    local session_dir = vim.fs.joinpath(upload_root, state.session_id)
    local real_upload = realpath(upload_root)
    local real_session = realpath(session_dir)
    local absolute = vim.fs.joinpath(state.project_root, result.path)
    local real_file = realpath(absolute)
    if not real_root or not real_upload or not real_session or not real_file
      or real_upload ~= upload_root or real_session ~= session_dir
      or not path_below(real_upload, real_root) or not path_below(real_session, real_upload) or not path_below(real_file, real_session)
    then
      return nil, "Bridge 返回了越界文件路径"
    end
    local stat = vim.uv.fs_stat(real_file)
    if not stat or stat.type ~= "file" then return nil, "Bridge 返回的文件不存在" end
    table.insert(lines, result.path)
  end
  if type(result.text) == "string" and result.text ~= "" then
    vim.list_extend(lines, vim.split(result.text, "\n", { plain = true }))
  end
  if #lines == 0 then return nil, "Bridge 完成结果为空" end
  return lines
end

local poll
local function retry_poll(state, message)
  if state.finished then return end
  state.retries = state.retries + 1
  if state.retries > require("maxa.config").runtime().telegram_bridge.upload.max_retries then
    cancel_bridge(state)
    return finish(state, "error", "Bridge 轮询失败: " .. message)
  end
  state.retry_timer = vim.defer_fn(function()
    state.retry_timer = nil
    poll(state)
  end, math.min(500 * (2 ^ (state.retries - 1)), 5000))
end

poll = function(state)
  if state.finished then return end
  client.poll_chat_upload(state.request_id, 30, function(ok, decoded, result)
    if state.finished then return end
    if not ok then return retry_poll(state, tostring(result and (result.stderr or result.code) or "transport error")) end
    state.retries = 0
    if type(decoded) ~= "table" or type(decoded.status) ~= "string" then
      cancel_bridge(state)
      return finish(state, "error", "Bridge 返回了无效轮询响应")
    end
    if decoded.status == "pending" or decoded.status == "downloading" or decoded.status == "creating" then return poll(state) end
    if decoded.status == "completed" then
      local lines, err = valid_result(state, decoded)
      if not lines then cancel_bridge(state); return finish(state, "error", err) end
      return finish(state, "completed", lines)
    end
    if decoded.status == "cancelled" then return finish(state, "cancelled") end
    if decoded.status == "failed" then
      local err = decoded.error
      return finish(state, "error", "Bridge 请求失败: " .. tostring(type(err) == "table" and (err.message or err.code) or "unknown"))
    end
    cancel_bridge(state)
    finish(state, "error", "Bridge 返回了未知状态: " .. decoded.status)
  end)
end

local function ensure_exit_hook()
  if exit_hook_group then return end
  exit_hook_group = vim.api.nvim_create_augroup("maxa_telegram_upload_exit", { clear = true })
  vim.api.nvim_create_autocmd("VimLeavePre", { group = exit_hook_group, callback = function()
    local active = {}
    for _, state in pairs(sessions) do table.insert(active, state) end
    for _, state in ipairs(active) do
      if not state.finished then cancel_bridge(state); finish(state, "cancelled") end
    end
  end })
end

local function install_hooks(state)
  state.augroup = vim.api.nvim_create_augroup("maxa_telegram_upload_" .. state.bufnr, { clear = true })
  vim.api.nvim_create_autocmd("User", { group = state.augroup, pattern = "MaxaAIChatClosed", callback = function(args)
    if args.data and args.data.bufnr == state.bufnr and not state.finished then cancel_bridge(state); finish(state, "cancelled") end
  end })
  vim.api.nvim_create_autocmd("BufDelete", { group = state.augroup, buffer = state.bufnr, callback = function()
    if not state.finished then cancel_bridge(state); finish(state, "cancelled") end
  end })
end

function M.start(chat, opts)
  opts = opts or {}
  if not valid_chat(chat) then notify("当前 Chat 不可用", vim.log.levels.ERROR); return nil end
  if not config.is_enabled() then notify("Telegram Bridge 未启用", vim.log.levels.ERROR); return nil end
  if busy(chat) then notify("Chat 正忙", vim.log.levels.WARN); return nil end
  if sessions[chat.bufnr] or require("maxa.session.chat_upload").active(chat.bufnr) then
    notify("当前 Chat 已有上传流程", vim.log.levels.WARN); return nil
  end
  local payload = status.chat_payload(chat)
  if not payload or not payload.project_root or not payload.save_id then notify("Chat 缺少 project_root/save_id", vim.log.levels.ERROR); return nil end
  local state = { chat = chat, bufnr = chat.bufnr, project_root = payload.project_root, save_id = payload.save_id, instance_id = hooks.instance(), retries = 0, finished = false, locked = false, insertion_context = opts.context }
  sessions[state.bufnr] = state
  ensure_exit_hook()
  local insertion = require("maxa.interactions.chat.slash_commands.insertion")
  insertion.track_context(chat, opts.context)
  -- Slash execution can race the periodic heartbeat after Chat creation/reload.
  -- Refresh exact open-chat state before Bridge validates the active primary.
  hooks.heartbeat(function(heartbeat_ok, _, heartbeat_result)
    if state.finished then return end
    if not heartbeat_ok then
      sessions[state.bufnr] = nil
      insertion.discard_anchor(chat, state.insertion_context)
      return notify("Bridge 心跳同步失败: " .. request_error(nil, heartbeat_result, "transport error"), vim.log.levels.ERROR)
    end
    client.create_chat_upload(caller(state), function(ok, decoded, result)
      if state.finished then return end
      if not ok or type(decoded) ~= "table" or decoded.status ~= "pending" or type(decoded.request_id) ~= "string" or type(decoded.session_id) ~= "string" then
        sessions[state.bufnr] = nil
        insertion.discard_anchor(chat, state.insertion_context)
        return notify("Bridge 创建请求失败: " .. request_error(decoded, result, "invalid response"), vim.log.levels.ERROR)
      end
      state.request_id, state.session_id = decoded.request_id, decoded.session_id
      local inserted, row, _, write_range = pcall(
        require("maxa.interactions.chat.slash_commands.insertion").add,
        chat,
        state.insertion_context,
        { content = PLACEHOLDER }
      )
      if not inserted or type(row) ~= "number" then cancel_bridge(state); return finish(state, "error", "无法插入 Telegram 等待提示") end
      state.placeholder_line = row
      state.placeholder_range = write_range
      pcall(vim.cmd, "stopinsert")
      local locked, err = pcall(chat.ui.lock_buf, chat.ui)
      if not locked then cancel_bridge(state); return finish(state, "error", "无法锁定 Chat: " .. tostring(err)) end
      state.locked = true
      install_hooks(state)
      poll(state)
    end)
  end)
  return state
end

function M.active(bufnr) return sessions[bufnr] end
M.placeholder = PLACEHOLDER
M._finish = finish
M._valid_result = valid_result
M._sessions = sessions
M._cancel_all = function()
  local active = {}
  for _, state in pairs(sessions) do table.insert(active, state) end
  for _, state in ipairs(active) do cancel_bridge(state); finish(state, "cancelled") end
end
return M
