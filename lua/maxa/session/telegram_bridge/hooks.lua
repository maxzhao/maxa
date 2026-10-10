local client = require("maxa.session.telegram_bridge.client")
local config_mod = require("maxa.session.telegram_bridge.config")
local inject = require("maxa.session.telegram_bridge.inject")
local status = require("maxa.session.telegram_bridge.status")

local M = { instance_id = nil, heartbeat_timer = nil, poll_active = false, registered = false }

function M.instance()
  if not M.instance_id then
    local seed = table.concat({ tostring(vim.uv.hrtime()), tostring(vim.fn.getpid()), tostring(math.random()) }, ":")
    M.instance_id = vim.fn.sha256(seed):sub(1, 32)
  end
  return M.instance_id
end

function M.register(cb)
  if not config_mod.is_enabled() then return end
  client.register_instance({
    instance_id = M.instance(),
    pid = vim.fn.getpid(),
    cwd = vim.uv.cwd() or vim.fn.getcwd(-1, -1),
    project_root = config_mod.project_root(vim.uv.cwd() or vim.fn.getcwd(-1, -1)),
    version = config_mod.get().version,
  }, function(ok, decoded)
    M.registered = ok
    if cb then cb(ok, decoded) end
  end)
end

function M.heartbeat(cb)
  if not config_mod.is_enabled() then return end
  if not M.registered then M.register() end
  client.heartbeat(M.instance(), { open_chats = status.open_chats() }, cb)
end

function M.start_heartbeat()
  if not config_mod.is_enabled() or M.heartbeat_timer then return end
  M.heartbeat()
  M.heartbeat_timer = vim.uv.new_timer()
  M.heartbeat_timer:start(config_mod.get().heartbeat_interval_ms, config_mod.get().heartbeat_interval_ms, function()
    vim.schedule(function() M.heartbeat() end)
  end)
end

function M.stop_heartbeat()
  if M.heartbeat_timer then
    M.heartbeat_timer:stop()
    M.heartbeat_timer:close()
    M.heartbeat_timer = nil
  end
end

function M.poll_once()
  if not config_mod.is_enabled() or M.poll_active then return end
  M.poll_active = true
  client.poll(M.instance(), config_mod.get().poll_timeout, function(ok, decoded)
    M.poll_active = false
    if ok and decoded and type(decoded.events) == "table" then
      for _, event in ipairs(decoded.events) do inject.inject_event(event) end
    end
    if config_mod.is_enabled() then
      vim.defer_fn(function() M.poll_once() end, 250)
    end
  end)
end

function M.setup_autocmds()
  local group = vim.api.nvim_create_augroup("MaxaTelegramBridge", { clear = true })
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = { "MaxaAIChatTitleChanged", "MaxaAIHistoryTitleRenamed", "MaxaAIChatSubmitted" },
    callback = function() M.heartbeat() end,
  })
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = { "MaxaAIChatDone", "MaxaAIChatStopped", "MaxaAIChatTerminalError", "MaxaAIChatClosed" },
    callback = function(args)
      local data = args.data or {}
      local ok, maxa_ai = pcall(require, "maxa")
      if ok and type(maxa_ai.buf_get_chat) == "function" and data.bufnr then
        local found, chat = pcall(maxa_ai.buf_get_chat, data.bufnr)
        if found and type(chat) == "table" then chat._telegram_bridge_active_request = nil end
      end
      M.heartbeat()
    end,
  })
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = group,
    callback = function()
      M.heartbeat()
      M.stop_heartbeat()
    end,
  })
end

function M.setup()
  if not config_mod.is_enabled() then return end
  M.register(function()
    M.start_heartbeat()
    M.poll_once()
  end)
  M.setup_autocmds()
end

return M
