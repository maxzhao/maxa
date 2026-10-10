local client = require("maxa.session.telegram_bridge.client")
local service = require("maxa.session.telegram_bridge.service")

local M = {}

function M.ping()
  client.health(function(ok, decoded, result)
    if ok then
      vim.notify("[telegram_bridge] health: " .. vim.inspect(decoded), vim.log.levels.INFO)
    else
      vim.notify("[telegram_bridge] health failed: " .. vim.trim((result and result.stderr or "") .. "\n" .. (result and result.stdout or "")), vim.log.levels.WARN)
    end
  end)
end

function M.setup()
  vim.api.nvim_create_user_command("TelegramBridgePing", M.ping, { desc = "Ping Telegram bridge" })
  vim.api.nvim_create_user_command("TelegramBridgeStart", service.start, { desc = "Start local Telegram bridge service" })
  vim.api.nvim_create_user_command("TelegramBridgeStop", service.stop, { desc = "Stop local Telegram bridge service started by this nvim" })
end

return M
