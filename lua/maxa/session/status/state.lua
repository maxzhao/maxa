local runtime_state = require("maxa.state")
local M = {}

local augroup
local redraw_timer

local spinners = require("maxa.config").runtime().status.spinner.spinners

local state = {
  request_count = 0,
  active_bufnr = nil,
  display_bufnr = nil,
  chats = {},
  warmup_count = 0,
  spinner_index = 1,
}

local function schedule_lualine_refresh()
  vim.schedule(function()
    local ok, lualine = pcall(require, "lualine")
    local refreshed = ok and type(lualine.refresh) == "function"
      and pcall(lualine.refresh, { place = { "statusline" } })
    if not refreshed then
      pcall(vim.cmd, "redrawstatus")
    end
  end)
end

local function any_chat_running()
  for _, chat_state in pairs(state.chats) do
    if chat_state.running then
      return true
    end
  end
  return false
end

local function running_chat_count()
  local count = 0
  for _, chat_state in pairs(state.chats) do
    if chat_state.running then
      count = count + 1
    end
  end
  return count
end

function M.is_busy()
  return state.request_count > 0 or state.warmup_count > 0 or any_chat_running()
end

local function stop_timer()
  if redraw_timer then
    redraw_timer:stop()
  end
end

local function ensure_timer()
  if not redraw_timer then
    redraw_timer = vim.uv.new_timer()
  end

  if M.is_busy() then
    redraw_timer:stop()
    redraw_timer:start(0, require("maxa.config").runtime().status.state.refresh_interval_ms, function()
      state.spinner_index = (state.spinner_index % #spinners) + 1
      schedule_lualine_refresh()
    end)
  else
    stop_timer()
    schedule_lualine_refresh()
  end
end

local function valid_bufnr(bufnr)
  return type(bufnr) == "number" and bufnr > 0 and vim.api.nvim_buf_is_valid(bufnr)
end

local function safe_get_chat(bufnr)
  if not valid_bufnr(bufnr) then
    return nil
  end

  local ok, maxa_ai = pcall(require, "maxa")
  if not ok or type(maxa_ai.buf_get_chat) ~= "function" then
    return nil
  end

  local success, chat = pcall(maxa_ai.buf_get_chat, bufnr)
  if success then
    return chat
  end
  return nil
end

local function model_from_chat(chat)
  if type(chat) ~= "table" or type(chat.settings) ~= "table" then
    return nil
  end

  local model = chat.settings.model
  if model ~= nil and type(model) ~= "table" then
    return model
  end

  return nil
end

local function model_from_adapter(adapter)
  if type(adapter) ~= "table" then
    return nil
  end

  if adapter.model ~= nil and type(adapter.model) ~= "table" then
    return adapter.model
  end

  local schema = adapter.schema
  if type(schema) == "table" and type(schema.model) == "table" then
    local default = schema.model.default
    if type(default) == "function" then
      local ok, value = pcall(default)
      if ok then
        return value
      end
    else
      return default
    end
  end

  return nil
end

local function positive_number(value)
  if type(value) == "number" and value > 0 then
    return value
  end
  if type(value) == "string" then
    local n = tonumber(value)
    if n and n > 0 then
      return n
    end
  end
  return nil
end

local function chat_status_meta(chat)
  if type(chat) ~= "table" or type(chat._meta) ~= "table" then
    return nil
  end
  local status = chat._meta.maxa_ai_status
  if type(status) == "table" then
    return status
  end
  return nil
end

local function capture_token_count(chat, bufnr)
  if type(chat) == "table" and chat.ui then
    local tokens = positive_number(chat.ui.tokens)
    if tokens then
      return tokens
    end
  end

  if bufnr and type(runtime_state.chat_metadata) == "table" then
    local metadata = runtime_state.chat_metadata[bufnr]
    if type(metadata) == "table" then
      local tokens = positive_number(metadata.tokens)
      if tokens then
        return tokens
      end
    end
  end

  local meta = chat_status_meta(chat)
  if meta then
    local tokens = positive_number(meta.tokens)
    if tokens then
      return tokens
    end
  end

  if type(chat) == "table" and chat.adapter then
    local tokens = positive_number(chat.adapter._total_tokens)
    if tokens then
      return tokens
    end
  end

  return nil
end

local function upsert_chat(bufnr, chat, event_data)
  if not valid_bufnr(bufnr) then
    return nil
  end

  local existing = state.chats[bufnr] or {}
  local adapter = event_data and event_data.adapter or (chat and chat.adapter)
  local event_model = event_data and event_data.model
  local chat_model = model_from_chat(chat)
  local model = chat_model or event_model or model_from_adapter(adapter)

  existing.bufnr = bufnr
  existing.id = (event_data and event_data.id) or (chat and chat.id) or existing.id
  existing.chat = chat or existing.chat

  if type(adapter) == "table" then
    existing.adapter = adapter
    existing.adapter_name = adapter.name or existing.adapter_name
    existing.adapter_display_name = adapter.formatted_name or adapter.name or existing.adapter_display_name
    existing.model = model or existing.model
  end

  if model ~= nil then
    existing.model = model
  end

  if chat and chat.adapter then
    existing.chat = chat
    existing.adapter_name = chat.adapter.name or existing.adapter_name
    existing.adapter_display_name = chat.adapter.formatted_name or chat.adapter.name or existing.adapter_display_name
    -- HTTP history restores keep the saved model in chat.settings while the
    -- resolved adapter still exposes today's default model. The per-chat setting
    -- is the request-effective value and must win over that adapter fallback.
    existing.model = chat_model or event_model or model_from_adapter(chat.adapter) or existing.model
  end

  local source_chat = chat or existing.chat
  local tokens = capture_token_count(source_chat, bufnr)
  if tokens then
    existing.last_tokens = tokens
    if type(source_chat) == "table" then
      source_chat._meta = source_chat._meta or {}
      local status = source_chat._meta.maxa_ai_status or {}
      status.tokens = tokens
      status.updated_at = os.time()
      source_chat._meta.maxa_ai_status = status
    end
  end

  state.chats[bufnr] = existing
  return existing
end

local function set_active_from_bufnr(bufnr)
  if not valid_bufnr(bufnr) then
    state.active_bufnr = nil
    state.display_bufnr = nil
    schedule_lualine_refresh()
    return
  end

  local chat = safe_get_chat(bufnr)
  if chat then
    state.active_bufnr = bufnr
    state.display_bufnr = bufnr
    upsert_chat(bufnr, chat)
  elseif state.chats[bufnr] then
    -- Chat 已停止时：buffer 仍是当前 chat，就继续保留它作为展示目标。
    state.active_bufnr = bufnr
    state.display_bufnr = bufnr
  else
    -- 展示目标只由当前 buffer 决定；后台 chat 事件不得保留或抢占它。
    state.active_bufnr = nil
    state.display_bufnr = nil
  end
  schedule_lualine_refresh()
end

local function current_event_data(args)
  local data = args and args.data
  if type(data) ~= "table" then
    data = {}
  end
  return data
end

local function event_bufnr(data)
  return tonumber(data.bufnr)
end

local function handle_request_started(args)
  state.request_count = state.request_count + 1
  local data = current_event_data(args)
  local bufnr = event_bufnr(data) or state.active_bufnr
  if bufnr then
    upsert_chat(bufnr, safe_get_chat(bufnr), data)
  end
  ensure_timer()
end

local function handle_request_finished()
  state.request_count = math.max(0, state.request_count - 1)
  ensure_timer()
end

local function handle_warmup_started(args)
  state.warmup_count = state.warmup_count + 1
  local data = current_event_data(args)
  local bufnr = event_bufnr(data) or state.active_bufnr
  if bufnr then
    local chat_state = upsert_chat(bufnr, safe_get_chat(bufnr), data)
    if chat_state then
      chat_state.running_before_warmup = chat_state.running == true
      chat_state.running = true
      chat_state.warming_up = true
    end
  end
  ensure_timer()
  schedule_lualine_refresh()
end

local function handle_warmup_finished(args)
  state.warmup_count = math.max(0, state.warmup_count - 1)
  local data = current_event_data(args)
  local bufnr = event_bufnr(data) or state.active_bufnr
  if bufnr then
    local chat_state = upsert_chat(bufnr, safe_get_chat(bufnr), data)
    if chat_state then
      chat_state.warming_up = false
      -- The real submit normally follows immediately after the warmup callback and
      -- will set running=true again via MaxaAIChatSubmitted. Only clear the
      -- running flag if warmup itself turned it on; do not stomp an already-running
      -- chat state.
      if not chat_state.running_before_warmup then
        chat_state.running = false
      end
      chat_state.running_before_warmup = nil
    end
  end
  ensure_timer()
  schedule_lualine_refresh()
end

local function handle_chat_event(args, running)
  local data = current_event_data(args)
  local bufnr = event_bufnr(data)
  if not bufnr then
    return
  end

  local chat = safe_get_chat(bufnr)
  local chat_state = upsert_chat(bufnr, chat, data)
  if chat_state and running ~= nil then
    chat_state.running = running
  end
  ensure_timer()
  schedule_lualine_refresh()
end

local function handle_chat_opened(args)
  handle_chat_event(args, nil)
  local bufnr = event_bufnr(current_event_data(args))
  if bufnr and bufnr == vim.api.nvim_get_current_buf() then
    set_active_from_bufnr(bufnr)
  end
end

local function handle_chat_hidden(args)
  local bufnr = event_bufnr(current_event_data(args))
  if bufnr and state.active_bufnr == bufnr and vim.api.nvim_get_current_buf() ~= bufnr then
    state.active_bufnr = nil
    state.display_bufnr = nil
    schedule_lualine_refresh()
  end
end

local function handle_chat_closed(args)
  local bufnr = event_bufnr(current_event_data(args))
  if bufnr then
    state.chats[bufnr] = nil
    if state.active_bufnr == bufnr then
      state.active_bufnr = nil
    end
    if state.display_bufnr == bufnr then
      state.display_bufnr = nil
    end
  end
  ensure_timer()
end

local function handle_chat_adapter(args)
  handle_chat_event(args, nil)
end

local function handle_chat_model(args)
  handle_chat_event(args, nil)
end

local function setup_autocmds()
  augroup = vim.api.nvim_create_augroup("util_maxa_ai_status", { clear = true })

  local user_events = {
    MaxaAIRequestStarted = handle_request_started,
    MaxaAIRequestFinished = handle_request_finished,
    MaxaAIChatCreated = function(args)
      handle_chat_event(args, false)
    end,
    MaxaAIChatOpened = handle_chat_opened,
    MaxaAIChatHidden = handle_chat_hidden,
    MaxaAIChatClosed = handle_chat_closed,
    MaxaAIChatSubmitted = function(args)
      handle_chat_event(args, true)
    end,
    MaxaAIChatDone = function(args)
      handle_chat_event(args, false)
    end,
    MaxaAIChatStopped = function(args)
      handle_chat_event(args, false)
    end,
    MaxaAIChatSoftStopped = function(args)
      handle_chat_event(args, false)
    end,
    MaxaAIChatAdapter = handle_chat_adapter,
    MaxaAIChatModel = handle_chat_model,
    MaxaAIDefaultSessionCacheWarmupStarted = handle_warmup_started,
    MaxaAIDefaultSessionCacheWarmupFinished = handle_warmup_finished,
  }

  for pattern, callback in pairs(user_events) do
    vim.api.nvim_create_autocmd("User", {
      group = augroup,
      pattern = pattern,
      callback = callback,
    })
  end

  vim.api.nvim_create_autocmd({ "BufEnter", "WinEnter" }, {
    group = augroup,
    callback = function(args)
      set_active_from_bufnr(args.buf)
    end,
  })

  vim.api.nvim_create_autocmd("BufDelete", {
    group = augroup,
    callback = function(args)
      state.chats[args.buf] = nil
      if state.active_bufnr == args.buf then
        state.active_bufnr = nil
      end
      if state.display_bufnr == args.buf then
        state.display_bufnr = nil
      end
    end,
  })
end

function M.setup(opts)
  opts = opts or {}
  if type(opts.spinners) == "table" and #opts.spinners > 0 then
    spinners = opts.spinners
  end

  setup_autocmds()
  set_active_from_bufnr(vim.api.nvim_get_current_buf())
end

function M.get_state()
  return state
end

function M.persist_chat_status(chat, bufnr)
  local source_chat = chat or safe_get_chat(bufnr or state.active_bufnr or state.display_bufnr)
  if type(source_chat) ~= "table" then
    return false
  end
  local tokens = capture_token_count(source_chat, bufnr or source_chat.bufnr)
  if not tokens then
    return false
  end
  source_chat._meta = source_chat._meta or {}
  local status = source_chat._meta.maxa_ai_status or {}
  status.tokens = tokens
  status.updated_at = os.time()
  source_chat._meta.maxa_ai_status = status
  return true
end

local function current_cursor_chat_state()
  local bufnr = vim.api.nvim_get_current_buf()
  if not valid_bufnr(bufnr) then
    state.active_bufnr = nil
    state.display_bufnr = nil
    return nil
  end

  local chat = safe_get_chat(bufnr)
  if chat then
    state.active_bufnr = bufnr
    state.display_bufnr = bufnr
    return upsert_chat(bufnr, chat)
  end

  local chat_state = state.chats[bufnr]
  if chat_state then
    -- A stopped chat may no longer be returned by MaxaAI, but its buffer
    -- still owns the statusline while the cursor remains there.
    state.active_bufnr = bufnr
    state.display_bufnr = bufnr
    return chat_state
  end

  -- BufEnter may have run before MaxaAI registered the chat. Re-evaluating
  -- from the current buffer on every read avoids depending on that event ordering.
  state.active_bufnr = nil
  state.display_bufnr = nil
  return nil
end

function M.get_active_chat_state()
  return current_cursor_chat_state()
end

function M.get_active_chat()
  local chat_state = M.get_active_chat_state()
  if not chat_state then
    return nil, nil
  end
  local chat = safe_get_chat(chat_state.bufnr) or chat_state.chat
  return chat, chat_state
end

function M.get_display_chat_state()
  return current_cursor_chat_state()
end

function M.get_display_chat()
  local chat_state = M.get_display_chat_state()
  if not chat_state then
    return nil, nil
  end
  local chat = safe_get_chat(chat_state.bufnr) or chat_state.chat
  return chat, chat_state
end

function M.spinner()
  local count = running_chat_count()
  if count > 0 then
    local symbol = spinners[state.spinner_index] or "⠋"
    return string.format("%s [%d]", symbol, count)
  end
  return "✓ [0]"
end

function M.running_chat_count()
  return running_chat_count()
end

function M.refresh()
  schedule_lualine_refresh()
end

function M.teardown()
  if redraw_timer then
    redraw_timer:stop()
    redraw_timer:close()
    redraw_timer = nil
  end
  if augroup then
    pcall(vim.api.nvim_del_augroup_by_id, augroup)
    augroup = nil
  end
end

return M
