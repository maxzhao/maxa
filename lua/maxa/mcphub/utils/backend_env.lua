local M = {}

---Build the backend process environment without broadcasting additions through MCP_HUB_ENV.
---@param context MCPHub.JobContext
---@param source table<string, string>|fun(context: MCPHub.JobContext): table<string, string>|nil
---@return table<string, string>|nil
---@return string|nil
function M.build(context, source)
    if type(source) == "function" then
        local ok, result = pcall(source, context)
        if not ok then
            return nil, "backend_env function failed"
        end
        if type(result) ~= "table" then
            return nil, "backend_env function must return a table"
        end
        source = result
    end
    if source ~= nil and type(source) ~= "table" then
        return nil, "backend_env must be a table or a function returning a table"
    end

    local env = vim.fn.environ()
    for key, value in pairs(source or {}) do
        if type(key) ~= "string" or not key:match("^[A-Za-z_][A-Za-z0-9_]*$") or type(value) ~= "string" then
            return nil, "backend_env entries must have environment variable names and string values"
        end
        if key == "MCP_HUB_ENV" then
            return nil, "use global_env instead of backend_env for MCP_HUB_ENV"
        end
        env[key] = value
    end
    env.CWD = context.cwd
    return env
end

return M
