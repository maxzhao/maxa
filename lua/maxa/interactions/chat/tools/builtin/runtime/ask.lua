local client_default = require("maxa.session.telegram_bridge.client")

local M = {}

local client = client_default
local active_by_chat = setmetatable({}, { __mode = "k" })
local active_by_buf = {}
local setup_done = false
local sequence = 0
local input_owner = require("maxa.interactions.chat.tools.input")
local ask_display = require("maxa.interactions.chat.tools.builtin.runtime.ask_display")
local function request_view(state, status, shortcuts)
  return ask_display.request(state.display_params or state.params, status, shortcuts)
end

local function valid_chat(chat)
  return type(chat) == "table"
    and type(chat.bufnr) == "number"
    and vim.api.nvim_buf_is_valid(chat.bufnr)
    and vim.api.nvim_buf_is_loaded(chat.bufnr)
end

local function display_module()
  return require("maxa.interactions.chat.tools.display")
end

local function request_id(chat, tool_call_id)
  sequence = sequence + 1
  local seed = table.concat({
    tostring(vim.uv.hrtime()),
    tostring(chat.bufnr),
    tostring(tool_call_id or "ask"),
    tostring(sequence),
  }, ":")
  return vim.fn.sha256(seed):sub(1, 32)
end

local function bridge_error(decoded, result)
  if type(client.error_message) == "function" then
    return client.error_message(decoded, result)
  end
  return "Telegram Bridge request failed"
end

local function stop_timer(state)
  if state.timer then
    pcall(state.timer.stop, state.timer)
    pcall(state.timer.close, state.timer)
    state.timer = nil
  end
end

local function lock_chat(chat)
  if not valid_chat(chat) then
    return
  end
  if chat.ui and type(chat.ui.lock_buf) == "function" then
    pcall(function()
      chat.ui:lock_buf()
    end)
  else
    vim.bo[chat.bufnr].modifiable = false
  end
end

local function unlock_chat(chat)
  if not valid_chat(chat) then
    return
  end
  if chat.ui and type(chat.ui.unlock_buf) == "function" then
    pcall(function()
      chat.ui:unlock_buf()
    end)
  else
    vim.bo[chat.bufnr].modifiable = true
  end
end

local function open_internal_chat_input(state)
  local chat = state.chat
  if not valid_chat(chat) then return end
  chat:add_buf_message({ role = require("maxa.config").constants.USER_ROLE, content = "" }, { force_role = true })
  chat.header_line = math.max(1, vim.api.nvim_buf_line_count(chat.bufnr) - 2)
  unlock_chat(chat)
end

local function best_effort_cancel_bridge(state)
  if not state.bridge_request_attempted or state.bridge_cancel_sent then
    return
  end
  state.bridge_cancel_sent = true
  pcall(client.cancel_human_assist, state.request_id, function() end)
end

local function finish(state, ok, value, source, opts)
  opts = opts or {}
  if state.terminal then
    return false
  end
  state.terminal = true
  require("maxa.interactions.chat.tools.builtin.runtime.ask_relay").remove(state)
  stop_timer(state)
  if state.input then state.input:close(); state.input = nil end
  if active_by_chat[state.chat] == state then
    active_by_chat[state.chat] = nil
  end
  if active_by_buf[state.bufnr] and active_by_buf[state.bufnr].state == state then
    active_by_buf[state.bufnr] = nil
  end

  if state.params.mode ~= "notify" then
    lock_chat(state.chat)
  end
  if opts.cancel_bridge then
    best_effort_cancel_bridge(state)
  end

  input_owner.restore_draft(state)
  display_module().clear_transient_ui(state.ui)
  if state.internal and valid_chat(state.chat) then
    state.ui:show(ask_display.display(state.params, { ok = ok, text = value }))
    open_internal_chat_input(state)
  end

  local callback = state.callback
  state.callback = nil
  if callback then
    callback(ok, value)
  end
  if state.tool_call_id and state.params.parse_mode ~= "HTML" then
    vim.schedule(function()
      if valid_chat(state.chat) then
        require("maxa.session.file_links").present(state.chat,
          { call_id = state.tool_call_id, phase = "request", all_fragments = true })
      end
    end)
  end
  return true
end

local function format_attachment(text, path)
  local attachment = "附件有:\n- " .. path
  if text and text ~= "" then
    return text .. "\n\n" .. attachment
  end
  return attachment
end

local function finish_telegram_result(state, data)
  if state.terminal then
    return
  end
  local result = type(data) == "table" and data.result or nil
  if type(result) ~= "table" or result.success ~= true then
    local message = type(result) == "table" and result.error or nil
    return finish(state, false, message or "Telegram request failed", "telegram")
  end

  if result.source == "chat" then
    if state.chat_candidate then
      return finish(state, true, state.chat_candidate, "chat")
    end
    return finish(state, false, "Chat completion is missing its local response", "chat")
  end

  local text = ""
  if result.selected ~= nil then
    text = '用户选择了"' .. tostring(result.selected) .. '"'
  elseif type(result.text) == "string" then
    text = result.text
  end

  if result.photo_file_id then
    client.download_human_assist_file(state.request_id, nil, function(ok, path, raw)
      if state.terminal then
        return
      end
      if not ok then
        return finish(state, false, bridge_error(nil, raw), "telegram")
      end
      finish(state, true, format_attachment(text, path), "telegram")
    end)
    return
  end

  finish(state, true, text, "telegram")
end

local poll_bridge

local function handle_bridge_state(state, data)
  if state.terminal or type(data) ~= "table" then
    return
  end
  if data.status == "pending" then
    return poll_bridge(state)
  end
  if data.status == "completed" then
    return finish_telegram_result(state, data)
  end
  local result = type(data.result) == "table" and data.result or {}
  local message = (data.status == "expired" and "ask timed out") or result.error or ("ask " .. tostring(data.status))
  finish(state, false, message, "telegram")
end

local function telegram_unavailable(state, detail)
  if state.terminal then
    return
  end
  state.telegram_available = false
  best_effort_cancel_bridge(state)
  state.telegram_error = detail
  if valid_chat(state.chat) then
    state.ui:show(request_view(state, "Telegram 不可用，等待 Chat 响应", state.shortcuts))
  end
  if state.chat_candidate then
    return finish(state, true, state.chat_candidate, "chat", { cancel_bridge = true })
  end
  if not valid_chat(state.chat) then
    finish(state, false, detail or "Chat and Telegram are unavailable", "telegram")
  end
end

poll_bridge = function(state)
  if state.terminal or not state.telegram_created then
    return
  end
  client.poll_human_assist(state.request_id, 20, function(ok, data, raw)
    if state.terminal then
      return
    end
    if not ok then
      state.telegram_error = bridge_error(data, raw)
      if valid_chat(state.chat) then
        state.ui:show(request_view(state, "Telegram 暂时不可用，等待 Chat 响应", state.shortcuts))
      end
      return vim.defer_fn(function()
        if not state.terminal and state.telegram_created then
          poll_bridge(state)
        end
      end, 1000)
    end
    handle_bridge_state(state, data)
  end)
end

local function complete_from_chat(state, candidate, attempt)
  if state.terminal then
    return
  end
  state.chat_candidate = candidate
  if not state.telegram_created or state.telegram_available == false then
    return finish(state, true, candidate, "chat", { cancel_bridge = state.bridge_request_attempted })
  end

  client.complete_human_assist(state.request_id, function(ok, data, raw)
    if state.terminal then
      return
    end
    if ok and type(data) == "table" and data.status ~= "pending" then
      return handle_bridge_state(state, data)
    end
    if attempt < 2 then
      return vim.defer_fn(function()
        complete_from_chat(state, candidate, attempt + 1)
      end, 250 * attempt)
    end
    telegram_unavailable(state, bridge_error(data, raw))
  end)
end

local function caller_context(chat)
  local ok, identity = pcall(require, "maxa.session.session_identity")
  local resolved = ok and identity.resolve(chat) or nil
  if type(resolved) == "table" then
    return {
      project_root = resolved.project_root,
      save_id = resolved.save_id,
    }
  end
  return nil
end

local function bridge_payload(state)
  local params = state.params
  local payload = {
    request_id = state.request_id,
    message = state.display_params and state.display_params.message or params.message,
    photo = params.photo,
    parse_mode = params.parse_mode,
    timeout = params.timeout,
    caller_context = caller_context(state.chat),
    ask_route = true,
  }
  if params.mode == "choice" then
    payload.buttons = {}
    for _, row in ipairs(params.choices) do
      local buttons = {}
      for _, item in ipairs(row) do
        table.insert(buttons, { text = item.label, data = item.value })
      end
      table.insert(payload.buttons, buttons)
    end
  end
  return payload
end

local function preceding_llm_text(chat, opts)
  if opts.internal then return nil end
  local messages = chat.messages or {}
  local index = #messages
  local message = messages[index]
  local calls = message and message.tools and message.tools.calls
  -- Chat:done stores response text separately from its own call-only record.
  -- Only the first call can immediately follow that response.
  if calls then
    local first = calls[1]
    if not first or not opts.tool_call_id
      or (first.call_id or first.id) ~= opts.tool_call_id
      or (type(message.content) == "string" and vim.trim(message.content) ~= "") then return nil end
    index = index - 1
    message = messages[index]
  end
  if not message or message.role ~= require("maxa.config").constants.LLM_ROLE
    or (message.opts and message.opts.visible == false) or message.tools
    or type(message.content) ~= "string" or vim.trim(message.content) == "" then return nil end
  return message.content, message
end

local function start_timer(state)
  local timeout = state.params.timeout
  if not timeout or timeout == 0 then
    return
  end
  local timer = vim.uv.new_timer()
  state.timer = timer
  timer:start(
    timeout * 1000,
    0,
    vim.schedule_wrap(function()
      if state.terminal then
        return
      end
      finish(state, false, "ask timed out", "timeout", { cancel_bridge = true })
    end)
  )
end

local function activate_chat_input(state)
  local chat = state.chat
  if not valid_chat(chat) then return false end
  input_owner.preserve_draft(state)
  display_module().set_request_view(state.ui, ask_display.request(state.params))
  state.ui:show(request_view(state, "等待 Chat / Telegram 响应"))
  if state.params.mode == "notify" then return true end
  local options = { mode = state.params.mode, choices = state.params.choices,
    on_cancel = function(reason) M.cancel(chat, reason, state.request_id) end }
  local lease, err = state.ui:input(options, function(value)
    if vim.trim(value) == "" then
      vim.notify("ask 响应不能为空", vim.log.levels.WARN)
      return false
    end
    if state.submitting then return true end
    state.submitting = true
    lock_chat(chat)
    local selected = state.input and state.input.selected == true
    complete_from_chat(state, selected and ('用户选择了"' .. value .. '"') or value, 1)
    return true
  end)
  if not lease then state.input_error = err; return false end
  state.input, state.shortcuts = lease, lease.shortcuts
  state.input_clear_start_row, state.input_start_row = lease.first, lease.input_row
  state.ui:show(request_view(state, "等待 Chat / Telegram 响应", state.shortcuts))
  state.input_clear_start_row, state.input_start_row = lease:rows()
  return true
end

local function start_bridge(state)
  local params = state.display_params or state.params
  if params.mode == "notify" then
    local payload = {
      message = params.message,
      photo = params.photo,
      parse_mode = params.parse_mode,
      caller_context = caller_context(state.chat),
      ask_route = true,
    }
    client.notify_human_assist(payload, function(ok, data, raw)
      if state.terminal then
        return
      end
      if ok then
        finish(state, true, "通知已发送", "telegram")
      elseif state.chat_available then
        finish(state, true, "通知已显示在 Chat；Telegram 投递失败", "chat")
      else
        finish(state, false, bridge_error(data, raw), "telegram")
      end
    end, function() return not state.terminal end)
    return
  end

  local create = params.mode == "choice" and client.create_human_assist_prompt or client.create_human_assist_input
  state.bridge_request_attempted = true
  create(bridge_payload(state), function(ok, data, raw)
    if state.terminal then
      if ok then
        state.telegram_created = true
        best_effort_cancel_bridge(state)
      end
      return
    end
    if not ok or type(data) ~= "table" or data.request_id ~= state.request_id then
      return telegram_unavailable(state, bridge_error(data, raw))
    end
    state.telegram_available = true
    state.telegram_created = true
    state.ui:show(request_view(state, "等待 Chat / Telegram 响应", state.shortcuts))
    handle_bridge_state(state, data)
  end)
end

local function setup()
  if setup_done then
    return
  end
  setup_done = true
  local group = vim.api.nvim_create_augroup("MaxaAskCoordinator", { clear = true })
  vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
    group = group,
    callback = function(args)
      local bufnr = args.buf
      local entry = active_by_buf[bufnr]
      if entry then
        vim.schedule(function()
          if active_by_buf[bufnr] ~= entry then
            return
          end
          local chat = entry.chat
          local Chat = package.loaded["maxa.interactions.chat"]
          if not valid_chat(chat) or (Chat and Chat.buf_get_chat(bufnr) ~= chat) then
            M.cancel(chat, "caller Chat was destroyed", entry.state.request_id)
          end
        end)
      end
    end,
  })
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = group,
    callback = function()
      for _, entry in pairs(vim.tbl_values(active_by_buf)) do
        M.cancel(entry.chat, "Neovim is exiting", entry.state.request_id)
      end
    end,
  })
end

function M.start(chat, params, callback, opts)
  opts = opts or {}
  if type(callback) ~= "function" then
    return false, "ask completion callback is required"
  end
  if active_by_chat[chat] or chat._tool_input then
    return false, "this Chat already has an active ask"
  end
  if not valid_chat(chat) then
    return false, "exact caller Chat is unavailable"
  end

  setup()
  local state = {
    chat = chat,
    bufnr = chat.bufnr,
    params = vim.deepcopy(params),
    callback = callback,
    request_id = opts.request_id or request_id(chat, opts.tool_call_id),
    tool_call_id = opts.tool_call_id,
    internal = opts.internal == true,
    preceding_text = preceding_llm_text(chat, opts),
    ui = opts.ui or display_module().create_ui(chat, opts.tool_call_id or ("internal_ask_" .. sequence), "ask", params),
  }
  active_by_chat[chat] = state
  active_by_buf[chat.bufnr] = { chat = chat, state = state }

  local function begin()
    if state.terminal then return end
    state.chat_available = activate_chat_input(state)
    if state.input_error then
      active_by_chat[chat], active_by_buf[chat.bufnr] = nil, nil
      finish(state, false, state.input_error, "chat")
      return
    end
    if not state.chat_available and params.mode ~= "notify" then lock_chat(chat) end
    if params.mode ~= "notify" then
      start_timer(state)
      require("maxa.interactions.chat.tools.builtin.runtime.ask_relay").enqueue(state, function(value, selected)
        if state.terminal or state.submitting then return false end
        if vim.trim(value) == "" then
          vim.notify("ask 响应不能为空", vim.log.levels.WARN)
          return false
        end
        state.submitting = true
        lock_chat(chat)
        complete_from_chat(state, selected and ('用户选择了"' .. value .. '"') or value, 1)
        return true
      end, function(reason) M.cancel(chat, reason, state.request_id) end)
    end
    if state.preceding_text then
      client.notify_human_assist({
        message = state.preceding_text,
        caller_context = caller_context(chat),
        ask_route = true,
      }, function(ok, data, raw)
        if state.terminal then return end
        if not ok then
          vim.notify("ask 前序正文 Telegram 投递失败: " .. bridge_error(data, raw), vim.log.levels.WARN)
        end
        start_bridge(state)
      end, function() return not state.terminal end)
    else
      start_bridge(state)
    end
  end
  local links = require("maxa.session.file_links")
  local _, predecessor = preceding_llm_text(chat, opts)
  if predecessor then links.present(chat, predecessor) end
  links.params(chat, state.params, function(copy)
    if state.terminal then return end
    state.display_params = copy
    if state.preceding_text then
      links.transform(chat, state.preceding_text, function(text)
        if state.terminal then return end
        state.preceding_text = text
        begin()
      end)
    else begin() end
  end)
  return true, state.request_id
end

function M.submit(chat, opts) return input_owner.submit(chat, opts) end

function M.choose(chat, expected_request_id, value)
  local state = active_by_chat[chat]
  if not state or state.terminal or state.submitting or state.params.mode ~= "choice"
    or state.request_id ~= expected_request_id then return false end
  for _, row in ipairs(state.params.choices or {}) do
    for _, item in ipairs(row) do if item.value == value and state.input then state.input.selected = true; return state.input:submit(value) end end
  end
  return false
end

function M.cancel(chat, reason, expected_request_id)
  local state = active_by_chat[chat]
  if not state or state.terminal then
    return false
  end
  if expected_request_id and state.request_id ~= expected_request_id then
    return false
  end
  -- Capture the batch that owns this input before finish() calls its runner.
  -- Internal requests have no tool batch to stop.
  local batch = not state.internal and chat.current_tool
  if batch and type(batch.cancel) == "function" then
    pcall(batch.cancel, reason or "ask cancelled")
  end
  finish(state, false, reason or "ask cancelled", "cancelled", { cancel_bridge = true })
  return true
end

function M.is_pending(chat)
  local state = active_by_chat[chat]
  return state ~= nil and not state.terminal and state.params.mode ~= "notify"
end

function M._test_set_client(value)
  client = value or client_default
end

function M._test_active(chat)
  return active_by_chat[chat]
end

function M._test_reset()
  for _, entry in pairs(vim.tbl_values(active_by_buf)) do
    stop_timer(entry.state)
    if entry.state.input then entry.state.input:close() end
  end
  active_by_chat = setmetatable({}, { __mode = "k" })
  active_by_buf = {}
  client = client_default
end

return M
