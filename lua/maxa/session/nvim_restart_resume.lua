-- Cross-process Neovim restart-resume bootstrap.
--
-- A tmux supervisor starts fresh Neovim with:
--   nvim --cmd 'let g:maxa_restart_resume_file="..."'
-- This module reads that pending file, deletes it, restores the editor session,
-- recreates the Maxa AI chat from save_id, waits for MCPHub readiness, and
-- auto-submits a resume message.

local M = {}

local POLL_MS = 500
local MAX_ATTEMPTS = 120
local STABLE_POLLS = 3

local state = {
  running = false,
}

local function notify(msg, level)
  vim.schedule(function()
    vim.notify("[nvim_restart_resume] " .. tostring(msg), level or vim.log.levels.INFO)
  end)
end

local function read_json(path)
  if type(path) ~= "string" or path == "" then
    return nil, "empty path"
  end
  if vim.fn.filereadable(path) == 0 then
    return nil, "file not readable: " .. path
  end
  local ok_lines, lines = pcall(vim.fn.readfile, path)
  if not ok_lines then
    return nil, tostring(lines)
  end
  local ok_json, data = pcall(vim.json.decode, table.concat(lines, "\n"))
  if not ok_json or type(data) ~= "table" then
    return nil, "invalid json: " .. tostring(data)
  end
  return data, nil
end

local function safe_delete(path)
  if type(path) == "string" and path ~= "" and vim.fn.filereadable(path) == 1 then
    pcall(vim.fn.delete, path)
  end
end

local function is_valid_resume_file(path)
  if type(path) ~= "string" or path == "" then
    return false
  end
  local normalized = vim.fs.normalize(path)
  return normalized:match("/%.maxa/tmp/nvim%-restart%-resume%.json$") ~= nil
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

local function mcphub_ready(baseline_dynamic)
  local ok, State = pcall(require, "maxa.mcphub.state")
  local hub = ok and State and State.hub_instance or nil
  if not hub then
    return false, "No MCPHub instance found"
  end
  local dynamic_ok = count_dynamic_tools() >= (baseline_dynamic or 0)
  return hub.ready and not hub.is_restarting and dynamic_ok, nil
end

local function wait_mcphub_ready(opts, callback)
  opts = opts or {}
  local baseline_dynamic = opts.baseline_dynamic or 0
  local attempts = 0
  local stable = 0

  local function poll()
    attempts = attempts + 1
    local ready, err = mcphub_ready(baseline_dynamic)
    if ready then
      stable = stable + 1
    else
      stable = 0
    end

    if stable >= STABLE_POLLS then
      callback(true)
      return
    end

    if attempts >= MAX_ATTEMPTS then
      callback(false, err or "MCPHub ready timeout")
      return
    end

    vim.defer_fn(poll, POLL_MS)
  end

  poll()
end

local function show_chat(chat)
  if type(chat) ~= "table" then
    return
  end
  if type(chat.open) == "function" then
    pcall(function()
      chat:open()
    end)
    return
  end
  if chat.ui and type(chat.ui.open) == "function" then
    pcall(function()
      chat.ui:open()
    end)
    return
  end
  if chat.bufnr and vim.api.nvim_buf_is_valid(chat.bufnr) then
    pcall(vim.api.nvim_set_current_buf, chat.bufnr)
  end
end

local function restore_persistence()
  local ok, persistence = pcall(require, "persistence")
  if ok and type(persistence.load) == "function" then
    pcall(persistence.load, { last = true })
  end
end

local function find_open_chat_by_save_id(save_id)
  local ok, maxa_ai = pcall(require, "maxa")
  if not ok or type(maxa_ai.buf_get_chat) ~= "function" then
    return nil
  end

  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(bufnr) then
      local chat_ok, chat = pcall(maxa_ai.buf_get_chat, bufnr)
      if chat_ok and type(chat) == "table" and chat.opts and chat.opts.save_id == save_id then
        return chat
      end
    end
  end
  return nil
end

local function append_resume_message(chat, payload)
  if type(chat) ~= "table" or type(chat.add_message) ~= "function" then
    return
  end
  local resume_message = payload.resume_message
    or "Neovim 已重启并恢复。请继续刚才因 Neovim 重启而中断的任务；不要重复已完成步骤，先检查当前状态，再继续后续执行。"
  chat:add_message({
    role = "user",
    content = resume_message,
  }, {
    visible = true,
    _meta = { tag = "nvim_restart_resume" },
  })
end

local function create_resume_chat(payload)
  if payload.fresh_chat == true then
    local chat = require("maxa").chat({ auto_submit = false })
    if not chat then return nil, "fresh restart Chat creation failed" end
    append_resume_message(chat, payload)
    return chat, nil
  end
  local resume_agent = require("maxa.mcphub.native_servers.subagent.tools.resume_agent")
  local create_resume_chat = resume_agent.create_resume_chat
    or (resume_agent._private and resume_agent._private.create_resume_chat)
  if type(create_resume_chat) ~= "function" then
    return nil, "resume_agent.create_resume_chat is not available"
  end

  local save_id = payload.save_id
  local resume_message = payload.resume_message
    or "Neovim 已重启并恢复。请继续刚才因 Neovim 重启而中断的任务；不要重复已完成步骤，先检查当前状态，再继续后续执行。"

  local chat, meta, err = create_resume_chat({
    save_id = save_id,
    goal_prompt = resume_message,
    resume_mode = "in_place",
    original_bufnr = vim.api.nvim_get_current_buf(),
  })
  if err then
    return nil, err
  end
  return chat, meta
end

function M.try_resume()
  if state.running then
    return
  end

  local path = vim.g.maxa_restart_resume_file
  if type(path) ~= "string" or path == "" then
    return
  end
  if not is_valid_resume_file(path) then
    notify("忽略非法 resume file 路径: " .. tostring(path), vim.log.levels.WARN)
    return
  end

  state.running = true
  local payload, err = read_json(path)
  safe_delete(path)
  if not payload then
    notify("读取 resume file 失败: " .. tostring(err), vim.log.levels.ERROR)
    state.running = false
    return
  end

  local save_id = payload.save_id
  if payload.fresh_chat ~= true and (type(save_id) ~= "string" or save_id == ""
    or save_id:find("/", 1, true) or save_id:find("\\", 1, true)) then
    notify("非法 save_id，取消恢复: " .. tostring(save_id), vim.log.levels.ERROR)
    state.running = false
    return
  end

  restore_persistence()

  vim.defer_fn(function()
    local baseline_dynamic = count_dynamic_tools()
    wait_mcphub_ready({ baseline_dynamic = baseline_dynamic }, function(ok, ready_err)
      if not ok then
        notify("MCPHub 未就绪，取消自动恢复 submit: " .. tostring(ready_err), vim.log.levels.WARN)
        state.running = false
        return
      end

      local chat = payload.fresh_chat ~= true and find_open_chat_by_save_id(save_id) or nil
      if chat then
        append_resume_message(chat, payload)
      else
        local created, meta_or_err = create_resume_chat(payload)
        if not created then
          notify("恢复 chat 失败: " .. tostring(meta_or_err), vim.log.levels.ERROR)
          state.running = false
          return
        end
        chat = created
      end

      show_chat(chat)

      if chat.current_request then
        notify("chat 仍在请求中，跳过自动 submit", vim.log.levels.WARN)
        state.running = false
        return
      end

      pcall(function()
        chat:submit({ auto_submit = true })
      end)
      notify("Neovim 重启恢复完成，已自动继续会话 save_id=" .. tostring(chat.opts and chat.opts.save_id or save_id))
      state.running = false
    end)
  end, 800)
end

function M.setup()
  vim.api.nvim_create_autocmd("VimEnter", {
    group = vim.api.nvim_create_augroup("MaxaNvimRestartResume", { clear = true }),
    once = true,
    callback = function()
      vim.defer_fn(function()
        M.try_resume()
      end, 500)
    end,
  })
end

return M
