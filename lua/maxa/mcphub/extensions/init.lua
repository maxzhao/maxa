local M = {}
local active

---@alias MCPHub.Extensions.Type "avante" | "copilotchat"
---@alias MCPHub.ActionType "use_mcp_tool" | "access_mcp_resource"

---@class MCPHub.Extensions.AvanteConfig
---@field enabled boolean Whether the extension is enabled or not
---@field make_slash_commands boolean Whether to make slash commands or not

---@class MCPHub.Extensions.CopilotChatConfig
---@field enabled boolean Whether the extension is enabled or not
---@field convert_tools_to_functions boolean Whether to convert MCP tools to CopilotChat functions
---@field convert_resources_to_functions boolean Whether to convert MCP resources to CopilotChat functions
---@field add_mcp_prefix boolean Whether to add "mcp_" prefix to function names

---@class MCPHub.Extensions.Config
---@field avante MCPHub.Extensions.AvanteConfig Configuration for the Avante extension
---@field copilotchat MCPHub.Extensions.CopilotChatConfig Configuration for the CopilotChat extension

---@param config MCPHub.Extensions.Config
function M.setup(config)
    if active then
        return
    end
    active = true
    local ok, err = xpcall(function()
        local avante_config = config.avante or {}
        if avante_config.enabled then
            require("maxa.mcphub.extensions.avante").setup(avante_config)
        end

        local copilotchat_config = config.copilotchat or {}
        if copilotchat_config.enabled then
            require("maxa.mcphub.extensions.copilotchat").setup(copilotchat_config)
        end
    end, debug.traceback)
    if not ok then
        M.rollback_setup()
        error(err)
    end
end

function M.rollback_setup()
    if not active then
        return
    end
    local avante = package.loaded["maxa.mcphub.extensions.avante.slash_commands"]
    if avante and type(avante.teardown) == "function" then
        avante.teardown()
    end
    local copilotchat = package.loaded["maxa.mcphub.extensions.copilotchat.functions"]
    if copilotchat and type(copilotchat.teardown) == "function" then
        copilotchat.teardown()
    end
    active = false
end

return M
