-- Neovim restart + current Maxa AI chat resume entrypoint for tmux.
--
-- Agent usage:
--   :lua dofile("abilities/mcp-creator/scripts/restart_nvim_resume.lua")
--
-- This script queues an out-of-process tmux restart. It must return before the
-- old Neovim exits, so callers should stop after receiving the OK message.

if arg and (arg[1] == "--help" or arg[1] == "-h") then
  print([[restart_nvim_resume.lua
Agent 用途：
  在 tmux 中重启当前 Neovim，并在新进程启动后按当前 chat save_id 自动恢复并继续。

适用范围：
  - 仓库内建 MCPHub Lua 或 Native Lua/MCP Server 变更后需要完整重启 Neovim 的场景
  - 仅支持 tmux

推荐调用：
  :lua dofile("abilities/mcp-creator/scripts/restart_nvim_resume.lua")

  行为说明：
    - 先确认当前 Neovim 中有且仅有调用方 chat 正在运行；其他 chat 可存在但必须空闲
    - 拒绝 temporary/unsavable 或没有 save_id 的 chat；完整重启只允许历史可持久化会话
    - 保存该运行中的 Maxa AI chat
  - 写入 .maxa/tmp/nvim-restart-resume.json
  - 启动 detached supervisor
  - 当前 Neovim 退出
  - supervisor 在同一 tmux pane 启动 nvim --cmd 'let g:maxa_restart_resume_file="..."'
  - 新 Neovim 读取 pending 文件后删除，恢复 chat，等待 MCPHub ready，然后自动 submit
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
    return nil, "current chat has no save_id; restart-resume requires a history-backed Maxa AI chat"
  end

  local core_ok, history_core = pcall(require, "maxa.session.history_core")
  if not core_ok then
    return nil, "failed to load session history_core for session safety check: " .. tostring(history_core)
  end
  if type(history_core.is_unsavable_save_id) == "function" and history_core.is_unsavable_save_id(save_id) then
    return nil,
      "unsafe to restart Neovim: current chat is temporary/unsavable (save_id="
        .. save_id
        .. "); switch to a history-backed chat before restarting"
  end

  if save_id:find("/", 1, true) or save_id:find("\\", 1, true) then
    return nil, "unsafe to restart Neovim: current chat has invalid save_id=" .. save_id
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

local function project_root()
  return vim.fs.root(0, { ".maxa" }) or vim.loop.cwd() or vim.fn.getcwd(-1, -1)
end

local function has_modified_file_buffers()
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) and vim.bo[bufnr].modified and vim.bo[bufnr].buftype == "" then
      return true, bufnr
    end
  end
  return false, nil
end

local chat, chat_err = get_single_running_chat()
if not chat then
  fail(chat_err)
  return
end

local pre_restart_save_id, persist_err = validate_history_backed_chat(chat)
if persist_err then
  fail(persist_err)
  return
end

local modified, modified_bufnr = has_modified_file_buffers()
if modified then
  fail("modified file buffer exists (bufnr=" .. tostring(modified_bufnr) .. "); save changes before Neovim restart-resume")
  return
end

if vim.env.TMUX == nil or vim.env.TMUX == "" then
  fail("restart_nvim_resume requires tmux; $TMUX is empty")
  return
end

local pane = vim.env.TMUX_PANE
if type(pane) ~= "string" or pane == "" then
  fail("restart_nvim_resume requires $TMUX_PANE; cannot safely target the original Neovim pane")
  return
end

local resolved_pane = vim.fn.system({ "tmux", "display-message", "-p", "-t", pane, "#{pane_id}" }):gsub("%s+$", "")
if vim.v.shell_error ~= 0 or resolved_pane == "" then
  fail("failed to resolve original tmux pane from $TMUX_PANE=" .. tostring(pane))
  return
end
pane = resolved_pane

local history_ok, history_session = pcall(require, "maxa.session.history_session")
if not history_ok then
  fail("failed to load session history_session: " .. tostring(history_session))
  return
end
local history_api = history_session.get_history_api and history_session.get_history_api() or nil
if not history_api or type(history_api.save_chat) ~= "function" then
  fail("history API save_chat is not available")
  return
end

local save_ok, save_err = pcall(history_api.save_chat, chat)
if not save_ok then
  fail("failed to save current chat: " .. tostring(save_err))
  return
end

local sub_ok, sub_utils = pcall(require, "maxa.mcphub.native_servers.subagent.utils")
local save_id = sub_ok and sub_utils.get_chat_save_id(chat) or (chat.opts and chat.opts.save_id)
if type(save_id) ~= "string" or save_id == "" then
  save_id = pre_restart_save_id
end
local _, post_save_err = validate_history_backed_chat(chat)
if post_save_err then
  fail(post_save_err)
  return
end

local root = project_root()
-- Explicit one-shot namespace/data cutover. Normal restart-resume stays unchanged.
local cutover = vim.g.maxa_restart_cutover
if cutover ~= nil then
  if type(cutover) ~= "table" or type(cutover.command_file) ~= "string"
    or vim.fn.filereadable(cutover.command_file) ~= 1
    or type(cutover.resume_file) ~= "string"
    or type(cutover.resume_message) ~= "string" or cutover.resume_message == "" then
    fail("invalid restart cutover configuration")
    return
  end
end
local tmp_dir = root .. "/.maxa/tmp"
vim.fn.mkdir(tmp_dir, "p")
local resume_file = tmp_dir .. "/nvim-restart-resume.json"
local payload = {
  save_id = save_id,
  project_root = root,
  cwd = vim.loop.cwd() or vim.fn.getcwd(-1, -1),
  created_at = os.time(),
  resume_message = cutover and cutover.resume_message
    or "Neovim 已重启并恢复。请继续刚才因 Neovim 重启而中断的任务；不要重复已完成步骤，先检查当前状态，再继续后续执行。",
  fresh_chat = cutover and true or nil,
}
local encoded = vim.json.encode(payload)
local write_ok, write_result = pcall(vim.fn.writefile, { encoded }, resume_file)
if not write_ok or write_result ~= 0 then
  fail("failed to write resume file: " .. tostring(write_result))
  return
end

local script_dir = debug.getinfo(1, "S").source:sub(2):match("(.*/)") or "abilities/mcp-creator/scripts/"
local supervisor = script_dir .. "restart_nvim_resume_supervisor.py"
local ability_root = vim.fs.dirname(vim.fs.normalize((script_dir:gsub("/$", ""))))
local command = {
  "uv", "run", "--project", ability_root, "python",
  supervisor,
  "--pane",
  pane,
  "--pid",
  tostring(vim.fn.getpid()),
  "--cwd",
  root,
  "--resume-file",
  cutover and cutover.resume_file or resume_file,
  "--nvim",
  vim.v.progpath or "nvim",
}
if cutover then
  vim.list_extend(command, { "--cutover-command-file", cutover.command_file })
  if cutover.resume_variable then
    vim.list_extend(command, { "--resume-variable", cutover.resume_variable })
  end
end
local job = vim.fn.jobstart(command, { detach = true })

if type(job) ~= "number" or job <= 0 then
  fail("failed to start restart supervisor")
  return
end

vim.defer_fn(function()
  vim.cmd("qa")
end, 100)

print("OK: Neovim restart-resume queued for save_id=" .. save_id .. "; current Neovim will exit and tmux will start a fresh Neovim")
