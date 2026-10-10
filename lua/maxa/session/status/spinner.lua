local M = {}

local uv = vim.uv or vim.loop

local augroup
local spinners_by_bufnr = {}
local bufnr_by_chat_id = {}
local tools_running_by_bufnr = {}
local tool_args_receiving_by_bufnr = {}
local response_started_by_bufnr = {}
local request_active_by_bufnr = {}

local function defaults() return require("maxa.config").runtime().status.spinner end
local namespace = vim.api.nvim_create_namespace("MaxaAIStatusSpinner")

local Spinner = {}
Spinner.__index = Spinner

local function valid_bufnr(bufnr)
  return type(bufnr) == "number" and bufnr > 0 and vim.api.nvim_buf_is_valid(bufnr)
end

local function loaded_bufnr(bufnr)
  return valid_bufnr(bufnr) and vim.api.nvim_buf_is_loaded(bufnr)
end

local function safe_clear(bufnr)
  if loaded_bufnr(bufnr) then
    pcall(vim.api.nvim_buf_clear_namespace, bufnr, namespace, 0, -1)
  end
end

local function format_elapsed_seconds(seconds)
  seconds = math.max(0, math.floor(seconds or 0))
  local hours = math.floor(seconds / 3600)
  local minutes = math.floor((seconds % 3600) / 60)
  local secs = seconds % 60

  if hours > 0 then
    return string.format("%dh%dm%ds", hours, minutes, secs)
  elseif minutes > 0 then
    return string.format("%dm%ds", minutes, secs)
  end
  return string.format("%ds", secs)
end

function Spinner.new(bufnr, chat_id, opts)
  opts = opts or {}
  return setmetatable({
    bufnr = bufnr,
    chat_id = chat_id,
    enabled = false,
    started = false,
    timer = nil,
    spinner_index = 0,
    spinner_symbols = opts.spinners or defaults().spinners,
    interval_ms = opts.interval_ms or defaults().interval_ms,
    default_text = opts.default_text or defaults().default_text,
    status_text_override = nil,
    started_at = nil,
    retry_state = nil,
    debounce_timer = nil,
    pending_start = nil,
  }, Spinner)
end

function Spinner:clear()
  safe_clear(self.bufnr)
  self.extmark_id = nil
end

local function format_retry_suffix(retry_state)
  if type(retry_state) ~= "table" or not retry_state.retry_count or retry_state.retry_count <= 0 then
    return ""
  end

  if retry_state.max_retries and retry_state.max_retries > 0 then
    return string.format(" · 重试 %d/%d", retry_state.retry_count, retry_state.max_retries)
  end
  return string.format(" · 重试 %d", retry_state.retry_count)
end

function Spinner:status_text()
  local text = self.status_text_override or self.default_text
  local elapsed = os.time() - (self.started_at or os.time())
  return string.format("%s %s%s", text, format_elapsed_seconds(elapsed), format_retry_suffix(self.retry_state))
end

function Spinner:update_text()
  if not (self.enabled and self.started) then
    self:clear()
    return
  end

  if not loaded_bufnr(self.bufnr) then
    self:destroy()
    return
  end

  self.spinner_index = (self.spinner_index % #self.spinner_symbols) + 1
  local symbol = self.spinner_symbols[self.spinner_index] or self.spinner_symbols[1] or "⠋"
  local last_line = math.max(vim.api.nvim_buf_line_count(self.bufnr) - 1, 0)

  local ok, id = pcall(vim.api.nvim_buf_set_extmark, self.bufnr, namespace, last_line, 0, {
    id = self.extmark_id,
    virt_lines = {
      { { "" } },
      { { symbol .. " " .. self:status_text(), "Comment" } },
    },
  })
  if ok then
    self.extmark_id = id
  end
end

function Spinner:start_timer()
  if self.timer or not uv then
    return
  end

  self.timer = uv.new_timer()
  self.timer:start(0, self.interval_ms, vim.schedule_wrap(function()
    self:update_text()
  end))
end

function Spinner:stop_timer()
  if not self.timer then
    return
  end

  pcall(function()
    self.timer:stop()
    self.timer:close()
  end)
  self.timer = nil
end

function Spinner:stop_debounce_timer()
  if not self.debounce_timer then
    return
  end

  pcall(function()
    self.debounce_timer:stop()
    self.debounce_timer:close()
  end)
  self.debounce_timer = nil
end

function Spinner:start_debounced(text_override, delay_ms)
  if self.debounce_timer and self.pending_start then
    self.pending_start.text_override = text_override
    return
  end

  self:stop_debounce_timer()
  self.pending_start = {
    text_override = text_override,
  }

  delay_ms = tonumber(delay_ms) or 0
  if delay_ms <= 0 or not uv then
    self:start(text_override)
    self.pending_start = nil
    return
  end

  self.debounce_timer = uv.new_timer()
  self.debounce_timer:start(delay_ms, 0, vim.schedule_wrap(function()
    self:stop_debounce_timer()
    local pending = self.pending_start
    self.pending_start = nil
    if pending then
      self:start(pending.text_override)
    end
  end))
end

function Spinner:update_state()
  if self.enabled and self.started and not tools_running_by_bufnr[self.bufnr] then
    self:start_timer()
    self:update_text()
  else
    self:stop_timer()
    self:clear()
  end
end

function Spinner:start(text_override)
  self:stop_debounce_timer()
  self.pending_start = nil
  self.started = true
  self.started_at = os.time()
  self.status_text_override = text_override
  self:update_state()
end

function Spinner:stop()
  self:stop_debounce_timer()
  self.pending_start = nil
  self.started = false
  self.started_at = nil
  self.status_text_override = nil
  self:update_state()
end

function Spinner:enable()
  self.enabled = true
  self:update_state()
end

function Spinner:disable()
  self.enabled = false
  self:update_state()
end

function Spinner:destroy()
  self.started = false
  self.enabled = false
  self.pending_start = nil
  self:stop_debounce_timer()
  self:stop_timer()
  self:clear()
end

local function event_data(args)
  local data = args and args.data
  if type(data) ~= "table" then
    return {}
  end
  return data
end

local function event_bufnr(args)
  local data = event_data(args)
  return tonumber(data.bufnr) or tonumber(args and args.buf)
end

local function event_chat_id(args)
  local data = event_data(args)
  if data.id ~= nil then
    return tostring(data.id)
  end
  return nil
end

local function get_spinner(args, opts)
  opts = opts or {}
  local bufnr = event_bufnr(args)
  local chat_id = event_chat_id(args)

  if not bufnr and chat_id then
    bufnr = bufnr_by_chat_id[chat_id]
  end

  if not valid_bufnr(bufnr) then
    return nil
  end

  local spinner = spinners_by_bufnr[bufnr]
  if not spinner and opts.create ~= false then
    spinner = Spinner.new(bufnr, chat_id, opts.spinner_opts)
    spinners_by_bufnr[bufnr] = spinner
  end

  if spinner and chat_id then
    spinner.chat_id = chat_id
    bufnr_by_chat_id[chat_id] = bufnr
  end

  return spinner, bufnr, chat_id
end

local function create_or_enable(args)
  local spinner = get_spinner(args, { create = true, spinner_opts = M.opts })
  if spinner then
    spinner:enable()
  end
end

local function start(args)
  local _, bufnr = get_spinner(args, { create = true, spinner_opts = M.opts })
  if bufnr then
    request_active_by_bufnr[bufnr] = true
    response_started_by_bufnr[bufnr] = nil
    tool_args_receiving_by_bufnr[bufnr] = nil
  end
  local spinner = get_spinner(args, { create = true, spinner_opts = M.opts })
  if spinner then
    spinner:enable()
    spinner:start()
  end
end

local function start_warmup(args)
  local spinner = get_spinner(args, { create = true, spinner_opts = M.opts })
  if spinner then
    spinner:enable()
    spinner:start("热启动中...")
  end
end

local function tool_args_key(data)
  if type(data) ~= "table" then
    return "__unknown"
  end
  return tostring(data.item_id or data.call_id or data.output_index or data.index or data.name or "__unknown")
end

local function tool_args_state(bufnr, create)
  local state = tool_args_receiving_by_bufnr[bufnr]
  if not state and create then
    state = { active = {}, order = {} }
    tool_args_receiving_by_bufnr[bufnr] = state
  end
  return state
end

local function tool_args_count(state)
  local count = 0
  if type(state) ~= "table" or type(state.active) ~= "table" then
    return count
  end
  for _ in pairs(state.active) do
    count = count + 1
  end
  return count
end

local function mark_tool_args_active(bufnr, data)
  local state = tool_args_state(bufnr, true)
  local key = tool_args_key(data)
  if not state.active[key] then
    table.insert(state.order, key)
    state.active[key] = {}
  end
  if type(data.name) == "string" and data.name ~= "" then
    state.active[key].name = data.name
  end
  return state
end

local function mark_tool_args_done(bufnr, data)
  local state = tool_args_state(bufnr, false)
  if not state then
    return nil, 0
  end

  state.active[tool_args_key(data)] = nil
  local count = tool_args_count(state)
  if count == 0 then
    tool_args_receiving_by_bufnr[bufnr] = nil
    return nil, 0
  end
  return state, count
end

local function first_tool_args_name(state)
  if type(state) ~= "table" or type(state.order) ~= "table" then
    return nil
  end
  for _, key in ipairs(state.order) do
    local item = state.active and state.active[key]
    if item and type(item.name) == "string" and item.name ~= "" then
      return item.name
    end
  end
end

local function tool_args_text(state, fallback)
  local count = tool_args_count(state)
  if count > 1 then
    return string.format("接收 %d 个工具参数中...", count)
  end

  local tool_name = first_tool_args_name(state)
  if type(tool_name) == "string" and tool_name ~= "" then
    return string.format("接收 %s 参数中...", tool_name)
  end
  return fallback or "接收工具参数中..."
end

local function tool_args_started(args)
  local spinner, bufnr = get_spinner(args, { create = true, spinner_opts = M.opts })
  if not bufnr then
    return
  end

  local state = mark_tool_args_active(bufnr, event_data(args))
  if spinner then
    spinner:enable()
spinner:start_debounced(tool_args_text(state, spinner.status_text_override), M.opts.tool_args_debounce_ms or defaults().tool_args_debounce_ms)
  end
end

local function tool_args_progress(args)
  local spinner, bufnr = get_spinner(args, { create = true, spinner_opts = M.opts })
  if not bufnr then
    return
  end

  local state = mark_tool_args_active(bufnr, event_data(args))
  if spinner then
    spinner:enable()
    if spinner.started then
      spinner.status_text_override = tool_args_text(state, spinner.status_text_override)
      spinner:update_state()
    else
      spinner:start_debounced(tool_args_text(state, spinner.status_text_override), M.opts.tool_args_debounce_ms or defaults().tool_args_debounce_ms)
    end
  end
end

local function tool_args_finished(args)
  local spinner, bufnr = get_spinner(args, { create = false })
  if not bufnr then
    return
  end

  local state, count = mark_tool_args_done(bufnr, event_data(args))
  if spinner then
    if count > 0 then
      spinner.status_text_override = tool_args_text(state, spinner.status_text_override)
      spinner:update_state()
    elseif response_started_by_bufnr[bufnr] or not request_active_by_bufnr[bufnr] then
      spinner:stop()
    else
      spinner:stop_debounce_timer()
      spinner.pending_start = nil
      spinner.status_text_override = nil
      if spinner.started then
        spinner:update_state()
      else
        spinner:start()
      end
    end
  end
end

local function stop(args)
  local spinner, bufnr = get_spinner(args, { create = false })
  if bufnr then
    tools_running_by_bufnr[bufnr] = nil
    tool_args_receiving_by_bufnr[bufnr] = nil
    response_started_by_bufnr[bufnr] = nil
    request_active_by_bufnr[bufnr] = nil
  end
  if spinner then
    spinner:stop()
  end
end

local function retry_state_changed(args)
  local spinner = get_spinner(args, { create = true })
  if not spinner then
    return
  end

  local data = args and args.data or {}
  local retry_count = tonumber(data.retry_count) or 0
  if retry_count > 0 then
    spinner.retry_state = {
      retry_count = retry_count,
      max_retries = tonumber(data.max_retries),
      adapter = data.adapter,
    }
  else
    spinner.retry_state = nil
  end
  spinner:update_state()
end

local function response_started(args)
  local spinner, bufnr = get_spinner(args, { create = false })
  if bufnr then
    tools_running_by_bufnr[bufnr] = nil
    response_started_by_bufnr[bufnr] = true
  end
  if spinner and not tool_args_receiving_by_bufnr[bufnr] then
    spinner:stop()
  end
end

local function tools_started(args)
  local spinner, bufnr = get_spinner(args, { create = false })
  if bufnr then
    tools_running_by_bufnr[bufnr] = true
    tool_args_receiving_by_bufnr[bufnr] = nil
  end
  if spinner then
    spinner:update_state()
  end
end

local function tools_finished(args)
  local spinner, bufnr = get_spinner(args, { create = false })
  if bufnr then
    tools_running_by_bufnr[bufnr] = nil
  end
  if spinner then
    spinner:update_state()
  end
end

local function hide(args)
  local spinner = get_spinner(args, { create = false })
  if spinner then
    spinner:disable()
  end
end

local function close(args)
  local spinner, bufnr, chat_id = get_spinner(args, { create = false })
  if spinner then
    spinner.retry_state = nil
    spinner:destroy()
  end
  if bufnr then
    spinners_by_bufnr[bufnr] = nil
    tools_running_by_bufnr[bufnr] = nil
    tool_args_receiving_by_bufnr[bufnr] = nil
    response_started_by_bufnr[bufnr] = nil
    request_active_by_bufnr[bufnr] = nil
  end
  if chat_id then
    bufnr_by_chat_id[chat_id] = nil
  end
end

local function cleanup_bufnr(bufnr)
  local spinner = spinners_by_bufnr[bufnr]
  if spinner then
    if spinner.chat_id then
      bufnr_by_chat_id[spinner.chat_id] = nil
    end
    spinner.retry_state = nil
    spinner:destroy()
    spinners_by_bufnr[bufnr] = nil
    tools_running_by_bufnr[bufnr] = nil
    tool_args_receiving_by_bufnr[bufnr] = nil
    response_started_by_bufnr[bufnr] = nil
    request_active_by_bufnr[bufnr] = nil
  else
    safe_clear(bufnr)
  end
end

local function setup_autocmds()
  augroup = vim.api.nvim_create_augroup("util_maxa_ai_status_spinner", { clear = true })

  local user_events = {
    MaxaAIChatCreated = create_or_enable,
    MaxaAIChatOpened = create_or_enable,
    MaxaAIChatSubmitted = start,
    MaxaAIChatDone = stop,
    MaxaAIChatResponseStarted = response_started,
    MaxaAIChatRetryStateChanged = retry_state_changed,
    MaxaAIToolCallArgumentsStarted = tool_args_started,
    MaxaAIToolCallArgumentsDelta = tool_args_progress,
    MaxaAIToolCallArgumentsDone = tool_args_finished,
    MaxaAIDefaultSessionCacheWarmupStarted = start_warmup,
    MaxaAIDefaultSessionCacheWarmupFinished = stop,
    MaxaAIChatStopped = stop,
    MaxaAIToolsStarted = tools_started,
    MaxaAIToolsFinished = tools_finished,
    MaxaAIChatHidden = hide,
    MaxaAIChatClosed = close,
  }

  for pattern, callback in pairs(user_events) do
    vim.api.nvim_create_autocmd("User", {
      group = augroup,
      pattern = pattern,
      callback = callback,
    })
  end

  vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
    group = augroup,
    callback = function(args)
      cleanup_bufnr(args.buf)
    end,
  })
end

function M.setup(opts)
  M.teardown()
  M.opts = opts or {}
  setup_autocmds()
end

function M.teardown()
  if augroup then
    pcall(vim.api.nvim_del_augroup_by_id, augroup)
    augroup = nil
  end

  for bufnr in pairs(spinners_by_bufnr) do
    cleanup_bufnr(bufnr)
  end
  spinners_by_bufnr = {}
  bufnr_by_chat_id = {}
  tool_args_receiving_by_bufnr = {}
  response_started_by_bufnr = {}
  request_active_by_bufnr = {}
end

function M.get(bufnr)
  return spinners_by_bufnr[bufnr]
end

function M._state()
  return {
    spinners_by_bufnr = spinners_by_bufnr,
    bufnr_by_chat_id = bufnr_by_chat_id,
  }
end

return M
