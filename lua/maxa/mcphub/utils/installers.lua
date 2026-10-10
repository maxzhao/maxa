local State = require("maxa.mcphub.state")
local prompt_utils = require("maxa.mcphub.utils.prompt")

-- Installer definitions and helpers
local Installers = {
    avante = {
        name = "Avante",
        check = function()
            local ok = pcall(require, "avante")
            return ok
        end,
        create_native_server = function(self)
            local guide = prompt_utils.get_native_server_prompt()
            if not guide then
                vim.notify("Native server guide not available", vim.log.levels.ERROR)
                return
            end
            local sidebar = require("avante").get()
            sidebar:new_chat()
            sidebar:add_chat_history({
                role = "user",
                content = guide,
            }, {
                visible = false,
            })
            local api = require("avante.api")
            api.ask({
                question = "I have provided you a guide to create Lua native MCP servers for mcphub.nvim plugin. My Neovim config directory is '"
                    .. vim.fn.stdpath("config")
                    .. "'. Once you understood the guide thoroughly, please ask me what kind of server, tools, or resources I want to create.",
                without_selection = true,
            })
        end,
    },
}

return Installers
