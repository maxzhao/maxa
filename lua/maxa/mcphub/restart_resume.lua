local M = {}

local POLL_MS = 500
local MAX_ATTEMPTS = 80
local STABLE_POLLS = 3
local MAX_RESUME_RETRIES = 240

M._state = nil

local function notify(msg, level)
  vim.schedule(function()
    vim.notify("[mcphub_control] " .. msg, level or vim.log.levels.INFO)
  end)
end

local function count_dynamic_tools()
  local ok, cc_config = pcall(require, "maxa.config")
  if not ok then
    return 0
  end

  local tools = cc_config.interactions
    and cc_config.interactions.chat
    and cc_config.interactions.chat.tools

  if type(tools) ~= "table" then
    return 0
  end

  local count = 0
  for _, v in pairs(tools) do
    if type(v) == "table" and v.id and tostring(v.id):sub(1, 11) == "mcp_dynamic" then
      count = count + 1
    end
  end
  return count
end

local function get_chat(bufnr)
  local ok, maxa_ai = pcall(require, "maxa")
  if not ok then
    return nil
  end

  if bufnr and bufnr > 0 and maxa_ai.buf_get_chat then
    local chat_ok, chat = pcall(maxa_ai.buf_get_chat, bufnr)
    if chat_ok and chat then
      return chat
    end
  end

  if maxa_ai.last_chat then
    local chat_ok, chat = pcall(maxa_ai.last_chat)
    if chat_ok and chat then
      return chat
    end
  end

  return nil
end

local function clear_state()
  M._state = nil
end

local function resume_chat(st)
  local chat = get_chat(st.bufnr)
  if not chat then
    notify("MCPHub 已恢复，但未找到原始 chat，跳过自动续跑", vim.log.levels.WARN)
    clear_state()
    return false
  end

  if chat.current_request then
    st.resume_retries = (st.resume_retries or 0) + 1
    if st.resume_retries <= MAX_RESUME_RETRIES then
      if st.resume_retries == 1 or st.resume_retries % 20 == 0 then
        notify(string.format("MCPHub 已恢复，等待 chat 空闲后自动续跑（第 %d 次检查）", st.resume_retries))
      end
      vim.defer_fn(function()
        resume_chat(st)
      end, POLL_MS)
      return false
    end
    notify("MCPHub 已恢复，但 chat 长时间仍忙碌，放弃自动续跑", vim.log.levels.WARN)
    clear_state()
    return false
  end

  st.pending = false

  chat:add_message({
    role = "user",
    content = st.resume_message,
  }, {
    visible = true,
    _meta = { tag = "mcphub_restart_resume" },
  })

  chat:submit({ auto_submit = true })
  notify("MCPHub 已恢复，已自动继续当前会话")
  clear_state()
  return true
end

local function poll_ready()
  local st = M._state
  if not st or not st.pending then
    return
  end

  st.attempts = (st.attempts or 0) + 1

  local ok, State = pcall(require, "maxa.mcphub.state")
  local hub = ok and State and State.hub_instance or nil
  if not hub then
    st.last_error = "No MCPHub instance found"
    notify(st.last_error, vim.log.levels.ERROR)
    clear_state()
    return
  end

  if st.api_err then
    notify(st.api_err, vim.log.levels.ERROR)
    clear_state()
    return
  end

  local ready = hub.ready and not hub.is_restarting
  local current_dynamic = count_dynamic_tools()
  local dynamic_ok = current_dynamic >= (st.baseline_dynamic or 0)

  if ready and dynamic_ok then
    st.stable_polls = (st.stable_polls or 0) + 1
  else
    st.stable_polls = 0
  end

  if st.stable_polls >= STABLE_POLLS then
    resume_chat(st)
    return
  end

  if st.attempts >= MAX_ATTEMPTS then
    notify(
      string.format(
        "等待 MCPHub 恢复超时：ready=%s restarting=%s dynamic=%d baseline=%d",
        tostring(hub.ready),
        tostring(hub.is_restarting),
        current_dynamic,
        st.baseline_dynamic or 0
      ),
      vim.log.levels.ERROR
    )
    clear_state()
    return
  end

  vim.defer_fn(poll_ready, POLL_MS)
end

function M.status()
  local ok, State = pcall(require, "maxa.mcphub.state")
  local hub = ok and State and State.hub_instance or nil
  local st = M._state or {}

  return {
    pending = not not st.pending,
    bufnr = st.bufnr,
    attempts = st.attempts or 0,
    stable_polls = st.stable_polls or 0,
    resume_retries = st.resume_retries or 0,
    baseline_dynamic = st.baseline_dynamic or 0,
    dynamic_tools = count_dynamic_tools(),
    last_error = st.last_error,
    hub_ready = hub and hub.ready or false,
    is_restarting = hub and hub.is_restarting or false,
  }
end

function M.request_restart_and_resume(opts)
  opts = opts or {}

  if M._state and M._state.pending then
    return false, "restart already pending"
  end

  local ok, State = pcall(require, "maxa.mcphub.state")
  local hub = ok and State and State.hub_instance or nil
  if not hub then
    return false, "No MCPHub instance found"
  end

  local chat = get_chat(opts.bufnr)
  local bufnr = opts.bufnr or (chat and chat.bufnr) or nil

  M._state = {
    pending = true,
    bufnr = bufnr,
    attempts = 0,
    stable_polls = 0,
    baseline_dynamic = count_dynamic_tools(),
    resume_message = opts.resume_message
      or "系统恢复通知：MCPHub 已重启并恢复就绪。请继续刚才因 MCPHub 重启而中断的任务；不要重复已完成步骤，先检查当前状态，再继续后续执行。",
  }

  if hub.is_restarting then
    notify("MCPHub 已在重启中，等待恢复后自动继续会话")
  elseif not hub.ready then
    notify("MCPHub 当前未就绪，等待启动完成后自动继续会话")
    pcall(function()
      hub:start()
    end)
  else
    hub:restart(function(success)
      local st = M._state
      if not st or not st.pending then
        return
      end
      if not success then
        st.api_err = "hard-restart API failed"
      end
    end)
    notify("已发起 MCPHub 重启，恢复后将自动继续当前会话")
  end

  vim.defer_fn(poll_ready, POLL_MS)
  return true, "queued"
end

function M.schedule_restart_and_resume(opts)
  opts = opts or {}
  local delay = opts.delay_ms or 100
  vim.defer_fn(function()
    local ok, err = M.request_restart_and_resume(opts)
    if not ok then
      notify("无法发起 MCPHub 重启：" .. tostring(err), vim.log.levels.ERROR)
    end
  end, delay)
  return true
end

return M
