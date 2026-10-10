local M = {}
local ui_utils = require("maxa.mcphub.utils.ui")
local utils = require("maxa.mcphub.utils")

---@class MCPHub.ParsedParams
---@field errors string[] List of errors encountered during parsing
---@field action MCPHub.ActionType Action type, either "use_mcp_tool" or "access_mcp_resource"
---@field server_name string Name of the server to call the tool/resource on
---@field tool_name string Name of the tool to call (nil for resources)
---@field arguments table Input arguments for the tool call (empty table for resources)
---@field uri string URI of the resource to access (nil for tools)

---@class MCPHub.ToolCallArgs
---@field server_name string Name of the server to call the tool on.
---@field tool_name string Name of the tool to call.
---@field tool_input table | string Input for the tool call. Must be an object for `use_mcp_tool` action.

---@class MCPHub.ResourceAccessArgs
---@field server_name string Name of the server to call the resource on.
---@field uri string URI of the resource to access.

---@param params MCPHub.ToolCallArgs | MCPHub.ResourceAccessArgs
---@param action_name MCPHub.ActionType
---@return MCPHub.ParsedParams
function M.parse_params(params, action_name)
    params = params or {}

    local server_name = params.server_name
    local tool_name = params.tool_name
    local uri = params.uri
    local arguments = params.tool_input or {}
    if type(arguments) == "string" then
        local json_ok, decode_result = utils.json_decode(arguments or "{}")
        if json_ok then
            arguments = decode_result or {}
        else
            arguments = {}
        end
    end
    local errors = {}
    if not vim.tbl_contains({ "use_mcp_tool", "access_mcp_resource" }, action_name) then
        table.insert(errors, "Action must be one of `use_mcp_tool` or `access_mcp_resource`")
    end
    if not server_name then
        table.insert(errors, "server_name is required")
    end
    if action_name == "use_mcp_tool" and not tool_name then
        table.insert(errors, "tool_name is required")
    end
    if action_name == "use_mcp_tool" and type(arguments) ~= "table" then
        table.insert(errors, "tool_input must be an object")
    end

    if action_name == "access_mcp_resource" and not uri then
        table.insert(errors, "uri is required")
    end

    return {
        errors = errors,
        action = action_name or "nil",
        server_name = server_name or "nil",
        tool_name = tool_name or "nil",
        arguments = arguments or {},
        uri = uri or "nil",
    }
end

---@param arguments MCPPromptArgument[]
---@param callback fun(values: string[])
function M.collect_arguments(arguments, callback)
    local values = {}
    local should_proceed = true

    local function collect_input(index)
        if index > #arguments and should_proceed then
            callback(values)
            return
        end

        local arg = arguments[index]
        local title = string.format("%s %s", arg.name, arg.required and "(required)" or "")
        local default = arg.default or ""

        local function submit_input(input)
            if arg.required and (input == nil or input == "") then
                vim.notify("Value for " .. arg.name .. " is required", vim.log.levels.ERROR)
                should_proceed = false
                return
            end

            values[arg.name] = input
            collect_input(index + 1)
        end

        local function cancel_input()
            if arg.required then
                vim.notify("Value for " .. arg.name .. " is required", vim.log.levels.ERROR)
                should_proceed = false
                return
            end
            values[arg.name] = nil
            collect_input(index + 1)
        end
        ui_utils.multiline_input(title, default, submit_input, { on_cancel = cancel_input })
    end

    if #arguments > 0 then
        vim.defer_fn(function()
            collect_input(1)
        end, 0)
    else
        callback(values)
    end
end

return M
