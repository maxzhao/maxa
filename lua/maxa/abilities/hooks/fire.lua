-- ability_hooks/fire.lua
-- 事件触发辅助函数
--
-- 统一的事件触发入口，确保：
--   1. 使用 vim.schedule 不阻塞当前执行流
--   2. 事件触发失败不影响原有逻辑
--   3. data 中自动包含 bufnr

local M = {}

local function attach_session_status(data)
  if type(data) ~= "table" then
    return data
  end
  if data._session_status ~= nil then
    return data
  end

  local ok, session_status = pcall(require, "maxa.session.session_status")
  if not ok then
    return data
  end

  local status = session_status.to_hook(session_status.current_from_bufnr(data.bufnr))
  if status then
    data._session_status = status
  end
  return data
end

local function prepare_data(data, phase)
  data = attach_session_status(data or {}) or {}
  data._ability_hook_phase = phase or "post"
  return data
end

--- 触发 AbilityHook 事件（安全、异步，默认只投递 inject_at=post hooks）
---@param event_name string 事件名（不含 AbilityHook 前缀）
---@param data table 事件数据（必须包含 bufnr）
function M.fire(event_name, data)
  if not event_name or event_name == "" then
    return
  end
  -- 异步触发，不阻塞当前执行流
  vim.schedule(function()
    local ok, err = pcall(vim.api.nvim_exec_autocmds, "User", {
      pattern = "AbilityHook" .. event_name,
      data = prepare_data(data, "post"),
    })
    if not ok then
      vim.notify(
        string.format("[ability_hooks] Failed to fire event '%s': %s", event_name, tostring(err)),
        vim.log.levels.DEBUG
      )
    end
  end)
end

--- 同步触发 AbilityHook 事件（只投递 inject_at=pre hooks），并在返回前刷新 hook 注入队列。
---@param event_name string 事件名（不含 AbilityHook 前缀）
---@param data table 事件数据（必须包含 bufnr/chat_id）
function M.fire_sync(event_name, data)
  if not event_name or event_name == "" then
    return
  end
  data = prepare_data(data, "pre")
  local ok, err = pcall(vim.api.nvim_exec_autocmds, "User", {
    pattern = "AbilityHook" .. event_name,
    data = data,
  })
  if not ok then
    vim.notify(
      string.format("[ability_hooks] Failed to fire sync event '%s': %s", event_name, tostring(err)),
      vim.log.levels.DEBUG
    )
    return
  end

  local chat_id = data.chat_id
  if type(chat_id) == "number" then
    local inject_ok, injector = pcall(require, "maxa.abilities.hooks.injector")
    if inject_ok and injector.flush_chat then
      injector.flush_chat(chat_id)
    end
  end
end

--- 从 req.caller 获取 chat 的 bufnr
---@param req table MCP 工具请求对象
---@return number|nil bufnr
function M.get_bufnr_from_req(req)
  if req and req.caller and req.caller.maxa_ai then
    local agent = req.caller.maxa_ai
    if agent.chat and agent.chat.bufnr then
      return agent.chat.bufnr
    end
  end
  -- 降级：使用 last_chat
  local ok, maxa_ai = pcall(require, "maxa")
  if ok and maxa_ai.last_chat then
    local chat = maxa_ai.last_chat()
    if chat then
      return chat.bufnr
    end
  end
  return nil
end

return M
