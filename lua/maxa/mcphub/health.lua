---@diagnostic disable: deprecated
local start = vim.health.start or vim.health.report_start --[[@as function]]
local ok = vim.health.ok or vim.health.report_ok --[[@as function]]
local info = vim.health.info or vim.health.report_info --[[@as function]]
local warn = vim.health.warn or vim.health.report_warn --[[@as function]]
local error = vim.health.error or vim.health.report_error --[[@as function]]

local fmt = string.format

local M = {}

M.deps = {
    {
        name = "plenary.nvim",
        plugin_name = "plenary",
    },
}

M.libraries = {
    {
        name = "curl",
    },
    {
        name = "node",
    },
    {
        name = "uv",
        optional = true,
        failed_msg = fmt("uv not found: Install with `%s`", "curl -LsSf https://astral.sh/uv/install.sh | sh"),
    },
}

M.chat_plugins = {
    {
        name = "avante.nvim",
        plugin_name = "avante",
        optional = true,
    },
    {
        name = "CopilotChat.nvim",
        plugin_name = "CopilotChat",
        optional = true,
    },
}

local function plugin_available(name)
    local check, _ = pcall(require, name)
    return check
end

local function lib_available(lib)
    if vim.fn.executable(lib) == 1 then
        return true
    end
    return false
end

function M.check()
    start("Maxa MCPHub")

    local version = require("maxa.mcphub.utils.version")
    info(fmt("MCPHub version: %s", version.PLUGIN_VERSION))
    info("mcp-hub binary:")

    --find mcp-hub
    local State = require("maxa.mcphub.state")
    local validation = require("maxa.mcphub.utils.validation")
    local merged_config = State.config
    local cmd = merged_config.cmd or require("maxa.mcphub.utils").get_bundled_mcp_path()
    local cmdArgs = merged_config.cmdArgs or {}
    local required_version = version.REQUIRED_NODE_VERSION.string
    info("  mcp-hub required version: " .. required_version)
    local system_ok, result = pcall(function()
        return vim.system(require("maxa.mcphub.utils").clean_args({ cmd, cmdArgs, "--version" }), { text = true }):wait()
    end)
    local installed_version = system_ok and result and vim.trim(result.stdout or "") or ""
    if not system_ok or not result or result.code ~= 0 then
        error(fmt("mcp-hub not found: %s; run `just mcphub-backend-install`", cmd))
    elseif installed_version == required_version then
        info("  mcp-hub installed version: " .. installed_version)
    else
        warn(fmt("  mcp-hub installed version: %s", installed_version))
    end
    local validation_result = validation.validate_version(installed_version)
    if not validation_result.ok then
        error(fmt("mcp-hub version not compatible: %s", validation_result.error.message))
    else
        ok(fmt("mcp-hub version %s is compatible", installed_version))
    end

    start("Plugin Dependencies:")
    for _, plugin in ipairs(M.deps) do
        if plugin_available(plugin.plugin_name) then
            ok(fmt("%s installed", plugin.name))
        else
            if plugin.optional then
                warn(plugin.failed_msg or fmt("%s not found", plugin.name))
            else
                error(plugin.failed_msg or fmt("%s not found", plugin.name))
            end
        end
    end

    start("Libraries:")

    for _, library in ipairs(M.libraries) do
        if lib_available(library.name) then
            ok(fmt("%s installed", library.name))
        else
            if library.optional then
                warn(library.failed_msg or fmt("%s not found", library.name))
            else
                error(library.failed_msg or fmt("%s not found", library.name))
            end
        end
    end

    start("Chat plugins")
    for _, plugin in ipairs(M.chat_plugins) do
        if plugin_available(plugin.plugin_name) then
            ok(fmt("%s installed", plugin.name))
        else
            if plugin.optional then
                warn(plugin.failed_msg or fmt("%s not found", plugin.name))
            else
                error(plugin.failed_msg or fmt("%s not found", plugin.name))
            end
        end
    end
end

return M
