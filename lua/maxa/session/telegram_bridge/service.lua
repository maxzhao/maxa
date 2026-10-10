local M = { handle = nil }

function M.start()
  if M.handle then
    vim.notify("[telegram_bridge] service already started by this nvim", vim.log.levels.INFO)
    return
  end
  local root = vim.fn.stdpath("config")
  local bridge_root = root .. "/tools/telegram-bridge"
  M.handle = vim.system({ "uv", "run", "--project", bridge_root, "maxa-telegram-bridge", "run" }, { cwd = bridge_root, text = true }, function(result)
    M.handle = nil
    if result.code ~= 0 then
      vim.schedule(function()
        vim.notify("[telegram_bridge] service exited: " .. vim.trim((result.stderr or "") .. "\n" .. (result.stdout or "")), vim.log.levels.WARN)
      end)
    end
  end)
  vim.notify("[telegram_bridge] service starting", vim.log.levels.INFO)
end

function M.stop()
  if M.handle and type(M.handle.kill) == "function" then
    M.handle:kill(15)
    M.handle = nil
    vim.notify("[telegram_bridge] service stopped", vim.log.levels.INFO)
  end
end

return M
