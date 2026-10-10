-- MCPHub restart entrypoint for agent use
--
-- This script is intentionally asynchronous:
-- 1. It schedules the restart after the current mcphub tool call returns
-- 2. The async controller then waits for MCPHub readiness inside Neovim
-- 3. Once ready, it auto-submits the original chat again

if arg and (arg[1] == "--help" or arg[1] == "-h") then
  print([[restart_mcphub.lua

Agent 用途：
  通过当前 Neovim 实例异步重启 MCPHub，并在恢复后自动继续当前 chat。

适用范围：
  - External MCP Server 代码/配置变更
  - MCPHub 连接或 unchanged-manifest backend 刷新
  - 不适用于仓库内建 MCPHub 或 Native Server Lua 代码可靠重载；这类变更请改用 restart_nvim_resume.lua 自动完整重启 Neovim 并恢复当前 chat

推荐调用：
  :lua dofile("<ability_root>/scripts/restart_mcphub.lua")
  或在 agent 中先加载 neovim，再用 run(scope="@neovim:lua", command='dofile(...)')

  行为说明：
    - 先确认当前 Neovim 中有且仅有调用方 chat 正在运行；其他 chat 可存在但必须空闲
    - 拒绝 temporary/unsavable 或没有 save_id 的 chat；自动恢复只允许历史可持久化会话
    - 本脚本不会阻塞等待
  - 当前工具调用会先返回，随后才开始重启 MCPHub
  - MCPHub 恢复后，会自动在原 chat 中追加一条恢复消息并继续提交
]])
  return
end

local function fail(msg)
  print("ERROR: " .. tostring(msg))
end

local function chat_label(chat)
  local parts = { "bufnr=" .. tostring(chat and chat.bufnr or "?") }
  if type(chat) == "table" and type(chat.title) == "string" and chat.title ~= "" then
    table.insert(parts, "title=" .. vim.inspect(chat.title))
  end
  local save_id = type(chat) == "table" and chat.opts and chat.opts.save_id or nil
  if type(save_id) == "string" and save_id ~= "" then
    table.insert(parts, "save_id=" .. save_id)
  end
  return table.concat(parts, ", ")
end

local function active_tool_monitor_count(chat)
  local monitors = type(chat) == "table" and chat._tool_monitors or nil
  if type(monitors) ~= "table" then
    return 0
  end

  local count = 0
  for _, monitor in pairs(monitors) do
    if type(monitor) ~= "table" or monitor.monitoring ~= false then
      count = count + 1
    end
  end
  return count
end

local function is_chat_running(chat)
  return type(chat) == "table"
    and (chat.current_request ~= nil or chat.current_tool ~= nil or active_tool_monitor_count(chat) > 0)
end

local function validate_history_backed_chat(chat)
  local save_id = type(chat) == "table" and chat.opts and chat.opts.save_id or nil
  if type(save_id) ~= "string" or save_id == "" then
    return nil, "current chat has no save_id; restart scripts require a history-backed Maxa AI chat"
  end

  local core_ok, history_core = pcall(require, "maxa.session.history_core")
  if not core_ok then
    return nil, "failed to load session history_core for session safety check: " .. tostring(history_core)
  end
  if type(history_core.is_unsavable_save_id) == "function" and history_core.is_unsavable_save_id(save_id) then
    return nil,
      "unsafe to restart: current chat is temporary/unsavable (save_id="
        .. save_id
        .. "); switch to a history-backed chat before restarting"
  end

  if save_id:find("/", 1, true) or save_id:find("\\", 1, true) then
    return nil, "unsafe to restart: current chat has invalid save_id=" .. save_id
  end

  return save_id, nil
end

local function list_maxa_ai_chats()
  local cc_ok, maxa_ai = pcall(require, "maxa")
  if not cc_ok then
    return nil, "MaxaAI is not available"
  end
  if type(maxa_ai.buf_get_chat) ~= "function" then
    return nil, "MaxaAI buf_get_chat is not available"
  end

  local list_ok, entries = pcall(maxa_ai.buf_get_chat)
  if not list_ok or type(entries) ~= "table" then
    return nil, "failed to list Maxa AI chats: " .. tostring(entries)
  end

  local chats = {}
  for _, entry in pairs(entries) do
    local chat = type(entry) == "table" and (entry.chat or entry) or nil
    if type(chat) == "table" and type(chat.bufnr) == "number" and vim.api.nvim_buf_is_valid(chat.bufnr) then
      table.insert(chats, chat)
    end
  end
  return chats, nil
end

local function get_single_running_chat()
  local chats, err = list_maxa_ai_chats()
  if not chats then
    return nil, err
  end

  local running = {}
  for _, chat in ipairs(chats) do
    if is_chat_running(chat) then
      table.insert(running, chat)
    end
  end

  if #running == 1 then
    return running[1], nil
  end

  if #running == 0 then
    return nil, "no running Maxa AI chat found; restart scripts are agent-only and require exactly one running caller chat"
  end

  local labels = {}
  for _, chat in ipairs(running) do
    table.insert(labels, chat_label(chat))
  end
  return nil, "unsafe to restart: multiple Maxa AI chats are running ("
    .. tostring(#running)
    .. "): "
    .. table.concat(labels, "; ")
    .. ". Restart would interrupt other chats. Agent must ask the user for help and stop instead of forcing restart."
end

local chat, chat_err = get_single_running_chat()
if not chat then
  fail(chat_err)
  return
end

local _, persist_err = validate_history_backed_chat(chat)
if persist_err then
  fail(persist_err)
  return
end

local ok, control = pcall(require, "maxa.mcphub.restart_resume")
if not ok then
  fail("failed to load maxa.mcphub.restart_resume: " .. tostring(control))
  return
end

local bufnr = chat.bufnr

control.schedule_restart_and_resume({
  bufnr = bufnr,
  delay_ms = 100,
})

print(string.format(
  "OK: MCPHub restart queued%s; current call will return first, then auto-resume chat after recovery",
  bufnr and (" for chat bufnr=" .. bufnr) or ""
))
