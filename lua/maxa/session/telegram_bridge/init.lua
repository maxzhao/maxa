local config = require("maxa.session.telegram_bridge.config")
local commands = require("maxa.session.telegram_bridge.commands")
local hooks = require("maxa.session.telegram_bridge.hooks")

local M = {}

function M.setup(opts)
  config.setup(opts or {})
  commands.setup()
  hooks.setup()
end

function M.config()
  return config.get()
end

return M
