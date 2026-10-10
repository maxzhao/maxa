local M = {}

local SHUTDOWN_DELAY = 5 * 60 * 1000 -- 5 minutes

---@class MCPHub.WorkspaceConfig
---@field enabled boolean Master switch for workspace-specific hubs
---@field look_for string[] Files to search for (in order)
---@field port_range { min: number, max: number } Port range for workspace hubs
---@field reload_on_dir_changed boolean Whether to listen to DirChanged events to reload workspace config
---@field get_port fun(): number | nil Function that determines that returns the port

---@class MCPHub.Config
local defaults = {
    port = 37373, -- Default port for MCP Hub
    server_url = nil, -- In cases where mcp-hub is hosted somewhere, set this to the server URL e.g `http://mydomain.com:customport` or `https://url_without_need_for_port.com`
    config = vim.fn.stdpath("config") .. "/abilities/mcp.json", -- Global Ability-owned MCP definitions
    shutdown_delay = SHUTDOWN_DELAY, -- Delay before shutting down the mcp-hub
    mcp_request_timeout = 60000, --Timeout for MCP requests in milliseconds, useful for long running tasks
    ---@type table<string, NativeServerDef>
    native_servers = {},
    --- Custom function to parse json file (e.g `require'json5'.parse` from `https://github.com/Joakker/lua-json5 to parse json5 syntax for .vscode/mcp.json like files)
    ---@type function | nil
    json_decode = nil,
    explicit_server_activation = false, -- Register configured Servers without connecting them until explicit start
    use_bundled_binary = false, -- Retained setup field; this owned runtime always uses the repository-local binary
    ---@type table | fun(context: MCPHub.JobContext): table Global environment variables available to all MCP servers
    global_env = {}, -- Environment variables that will be available to all MCP servers
    ---@type table<string, string> | fun(context: MCPHub.JobContext): table<string, string>
    backend_env = {}, -- Backend-only variables; Servers receive them only through explicit config references
    ---@type string?
    cmd = nil, -- retained setup field; repository setup replaces it with the project-local executable
    ---@type table?
    cmdArgs = nil, -- retained setup field; repository setup replaces it with project-local arguments
    ---@type LogConfig
    log = {
        level = vim.log.levels.ERROR,
        to_file = false,
        file_path = nil,
        prefix = "MCPHub",
    },
    ---@type MCPHub.UIConfig
    ui = {
        window = {},
        wo = {},
    },
    ---@type MCPHub.Extensions.Config
    extensions = {
        avante = {
            enabled = true,
            make_slash_commands = true,
        },
        copilotchat = {
            enabled = true,
            convert_tools_to_functions = true,
            convert_resources_to_functions = true,
            add_mcp_prefix = false,
        },
    },
    ---@type MCPHub.WorkspaceConfig
    workspace = {
        enabled = true, -- Enables workspace-specific hubs
        look_for = { ".maxa/abilities/mcp.json", ".vscode/mcp.json", ".cursor/mcp.json" }, -- Files to search for (in order)
        reload_on_dir_changed = true, -- Whether to listen to DirChanged events to reload workspace config
        port_range = { min = 40000, max = 41000 }, -- Port range for workspace hubs
        -- function that determines that returns the port
        --- @type fun(): number | nil
        get_port = nil,
    },
    readiness_timeout = 15000, -- Maximum time in milliseconds for initial setup to reach Hub readiness
    on_ready = function() end,
    ---@param msg string
    on_error = function(msg) end,
}

---@param opts MCPHub.Config?
---@return MCPHub.Config
function M.setup(opts)
    M.config = vim.tbl_deep_extend("force", defaults, opts or {})
    return M.config
end

return setmetatable(M, {
    __index = function(_, key)
        if key == "setup" then
            return M.setup
        end
        return rawget(M.config, key)
    end,
})
