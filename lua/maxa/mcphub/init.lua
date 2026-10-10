local Error = require("maxa.mcphub.utils.errors")
local ImageCache = require("maxa.mcphub.utils.image_cache")
local Job = require("plenary.job")
local MCPHub = require("maxa.mcphub.hub")
local State = require("maxa.mcphub.state")
local log = require("maxa.mcphub.utils.log")
local native = require("maxa.mcphub.native")
local utils = require("maxa.mcphub.utils")
local validation = require("maxa.mcphub.utils.validation")

-- Initialize global variables for lualine integration
vim.g.mcphub_status = "stopped"
vim.g.mcphub_servers_count = 0
vim.g.mcphub_executing = false

local INSTALL_COMMAND = "just mcphub-backend-install"
local BACKEND_ERROR = "Project-local mcp-hub@4.2.1 is unavailable. Run `" .. INSTALL_COMMAND .. "` from the Maxa repository root."

---@class MCPHub
local M = {
    is_native_server = native.is_native_server,
    add_server = native.add_server,
    add_tool = native.add_tool,
    add_resource = native.add_resource,
    add_resource_template = native.add_resource_template,
    add_prompt = native.add_prompt,
}

---Get the current MCPHub instance
---@return MCPHub.Hub | nil
function M.get_hub_instance()
    if State.setup_state == "completed" then
        return State.hub_instance
    end
    if State.setup_state == "in_progress"
        and State.hub_instance
        and State.hub_instance.ready == true
    then
        return State.hub_instance
    end
    return nil
end

---Get the current state of the MCPHub
---@return MCPHub.State
function M.get_state()
    return State
end

---Get the explicit-cwd project-keyed transport without switching the UI Hub.
---@return table
function M.get_project_transport()
    return require("maxa.mcphub.project_transport")
end

---Resolve exact-cwd Chat transport even while the process-global UI Hub is still starting.
---@param cwd string
---@return MCPHub.JobContext|nil
---@return string|nil
function M.resolve_project_context(cwd)
    local hub = State.hub_instance
    if not hub then
        return nil, "MCPHub instance is unavailable"
    end
    return hub:resolve_project_context(cwd)
end

---@param event string | table
---@param callback fun(data: table)
function M.on(event, callback)
    --if event is an array then add each event
    if type(event) == "table" then
        for _, e in ipairs(event) do
            State:add_event_listener(e, callback)
        end
        return
    end
    State:add_event_listener(event, callback)
end

---@param event string | table
---@param callback fun(data: table)
function M.off(event, callback)
    --if event is an array then remove each event
    if type(event) == "table" then
        for _, e in ipairs(event) do
            State:remove_event_listener(e, callback)
        end
        return
    end
    State:remove_event_listener(event, callback)
end

local function setup_bootstrap()
    local bootstrap_ok, bootstrap_err = xpcall(function()
        require("maxa.mcphub.utils.highlights").setup()
    end, debug.traceback)
    if not bootstrap_ok then
        local err = Error("SETUP", Error.Types.SETUP.INVALID_CONFIG, "MCPHub bootstrap failed: " .. tostring(bootstrap_err))
        State:add_error(err)
        State:update({ setup_state = "failed" }, "setup")
        return false, err
    end
    if vim.fn.exists(":MaxaConfig") == 2 then
        return true
    end

    local command_ok, command_err = xpcall(function()
        vim.api.nvim_create_user_command("MaxaConfig", function(args)
        local config = State.config
        if State.setup_state == "not_started" then
            M.setup(config)
        end
        if State.ui_instance then
            State.ui_instance:toggle(args)
        else
            State.ui_instance = require("maxa.mcphub.ui"):new(config and config.ui or {})
            State.ui_instance:toggle(args)
        end
        end, {
            desc = "Maxa项目配置",
        })
    end, debug.traceback)
    if not command_ok then
        local err = Error("SETUP", Error.Types.SETUP.INVALID_CONFIG, "MCPHub command bootstrap failed: " .. tostring(command_err))
        State:add_error(err)
        State:update({ setup_state = "failed" }, "setup")
        return false, err
    end
    return true
end

--- Setup the repository-owned MCPHub runtime with error handling and validation
--- @param opts MCPHub.Config?
---@return MCPHub.Hub | nil
function M.setup(opts)
    local bootstrap_ok, bootstrap_err = setup_bootstrap()
    if not bootstrap_ok then
        if type(opts) == "table" and type(opts.on_error) == "function" then
            pcall(opts.on_error, tostring(bootstrap_err))
        end
        return nil
    end

    local attempt = {
        previous_status = vim.g.mcphub_status,
        previous_servers_count = vim.g.mcphub_servers_count,
        previous_executing = vim.g.mcphub_executing,
    }
    local pending_on_error = type(opts) == "table" and opts.on_error or nil
    local extensions = require("maxa.mcphub.extensions")

    local function cancel_readiness_timer()
        local timer = attempt.readiness_timer
        attempt.readiness_timer = nil
        if not timer then
            return
        end
        pcall(function()
            timer:stop()
            if not timer:is_closing() then
                timer:close()
            end
        end)
    end

    local function dispose_attempt()
        cancel_readiness_timer()
        if attempt.hub then
            attempt.hub._on_setup_ready = nil
            attempt.hub._on_setup_failed = nil
            attempt.hub._setup_disposed = true
            pcall(attempt.hub.stop, attempt.hub)
        end
        if attempt.extensions_started then
            extensions.rollback_setup()
            attempt.extensions_started = nil
        end
        if attempt.native_snapshot then
            native.rollback_setup(attempt.native_snapshot)
            attempt.native_snapshot = nil
        end
        if State.hub_instance == attempt.hub then
            State.hub_instance = nil
        end
        if attempt.ui then
            if type(attempt.ui.dispose) == "function" then
                pcall(attempt.ui.dispose, attempt.ui)
            elseif type(attempt.ui.cleanup) == "function" then
                pcall(attempt.ui.cleanup, attempt.ui)
            end
        end
        if State.ui_instance == attempt.ui then
            State.ui_instance = nil
        end
        ImageCache.dispose()
        pcall(vim.api.nvim_del_augroup_by_name, "mcphub_cleanup")
        vim.g.mcphub_status = attempt.previous_status
        vim.g.mcphub_servers_count = attempt.previous_servers_count
        vim.g.mcphub_executing = attempt.previous_executing
    end

    ---@param err MCPError
    local function _on_setup_failed(err)
        if State.setup_state ~= "in_progress" then
            return
        end
        dispose_attempt()
        State:add_error(err)
        State:update({
            setup_state = "failed",
        }, "setup")
        local on_error = type(pending_on_error) == "function" and pending_on_error or State.config.on_error
        if type(on_error) == "function" then
            local callback_ok, callback_err = pcall(on_error, tostring(err))
            if not callback_ok then
                log.error("MCPHub on_error callback failed: " .. tostring(callback_err))
            end
        end
    end

    local function setup_error(code, message, details)
        return Error("SETUP", code, message, details)
    end

    local function run_step(code, label, callback)
        local ok, result = xpcall(callback, debug.traceback)
        if not ok then
            _on_setup_failed(setup_error(code, label .. " failed: " .. tostring(result)))
            return false
        end
        return true, result
    end

    ---Version check handler
    ---@param job Job
    ---@param code number
    ---@param config MCPHub.Config
    local function _handle_version_check(job, code, config)
        if code ~= 0 then
            return _on_setup_failed(
                Error(
                    "SETUP",
                    Error.Types.SETUP.MISSING_DEPENDENCY,
                    "mcp-hub exited with non-zero code. " .. BACKEND_ERROR
                )
            )
        end

        -- Validate the exact repository-owned backend version.
        local installed_version = job:result()[1]
        local version_result = validation.validate_version(installed_version)
        if not version_result.ok or installed_version ~= "4.2.1" then
            return _on_setup_failed(
                Error("SETUP", Error.Types.SETUP.VERSION_MISMATCH, "Expected project-local mcp-hub@4.2.1, found " .. tostring(installed_version) .. ". " .. BACKEND_ERROR, {
                    found = installed_version,
                    required = "4.2.1",
                    install_cmd = INSTALL_COMMAND,
                })
            )
        end

        local hub_ok, hub = run_step(Error.Types.SETUP.SERVER_START, "MCPHub instance creation", function()
            return MCPHub:new(config)
        end)
        if not hub_ok then
            return
        end
        if not hub then
            return _on_setup_failed(setup_error(Error.Types.SETUP.SERVER_START, "Failed to create MCPHub instance"))
        end

        attempt.hub = hub
        State.hub_instance = hub
        hub._on_setup_failed = _on_setup_failed
        attempt.native_snapshot = native.snapshot_setup()
        hub._on_setup_ready = function(ready_hub)
            if State.setup_state ~= "in_progress" or State.hub_instance ~= ready_hub then
                return
            end
            attempt.extensions_started = true
            local extensions_ok = run_step(Error.Types.SETUP.INVALID_CONFIG, "MCPHub extension setup", function()
                extensions.setup(config.extensions)
            end)
            if not extensions_ok then
                return
            end
            local on_ready_ok = run_step(Error.Types.SETUP.SERVER_START, "MCPHub on_ready callback", function()
                config.on_ready(ready_hub)
            end)
            if not on_ready_ok then
                return
            end
            if not ready_hub.ready then
                return _on_setup_failed(setup_error(Error.Types.SETUP.SERVER_START, "MCPHub stopped during on_ready callback"))
            end
            cancel_readiness_timer()
            ready_hub._on_setup_ready = nil
            ready_hub._on_setup_failed = nil
            attempt.extensions_started = nil
            attempt.native_snapshot = nil
            State:update({
                setup_state = "completed",
            }, "setup")
        end

        if not run_step(Error.Types.SETUP.INVALID_CONFIG, "MCPHub UI setup", function()
            attempt.ui = require("maxa.mcphub.ui"):new(config.ui)
            State.ui_instance = attempt.ui
        end) then
            return
        end
        if not run_step(Error.Types.SETUP.INVALID_CONFIG, "MCPHub image cache setup", ImageCache.setup) then
            return
        end
        attempt.readiness_timer = vim.defer_fn(function()
            attempt.readiness_timer = nil
            if State.setup_state == "in_progress" and State.hub_instance == hub and not hub.ready then
                _on_setup_failed(setup_error(
                    Error.Types.SETUP.SERVER_START,
                    "MCPHub did not become ready within " .. tostring(config.readiness_timeout) .. "ms"
                ))
            end
        end, config.readiness_timeout)
        if not run_step(Error.Types.SETUP.SERVER_START, "MCPHub start", function()
            hub:start()
        end) then
            return
        end
        if State.setup_state == "in_progress" and not hub.is_starting and not hub.ready then
            _on_setup_failed(setup_error(Error.Types.SETUP.SERVER_START, "MCPHub start stopped before readiness"))
        end
    end
    -- Completed and in-progress setup are idempotent; failed setup remains retryable.
    if State.setup_state == "completed" or State.setup_state == "in_progress" then
        return State.hub_instance
    end
    State:update({
        setup_state = "in_progress",
    }, "setup")
    local config_ok, config = run_step(Error.Types.SETUP.INVALID_CONFIG, "MCPHub config setup", function()
        return require("maxa.mcphub.config").setup(opts)
    end)
    if not config_ok then
        return nil
    end
    State.config = config

    local validation_ok, validation_result = run_step(Error.Types.SETUP.INVALID_CONFIG, "MCPHub config validation", function()
        return validation.validate_setup_opts(config)
    end)
    if not validation_ok then
        return nil
    end
    if not validation_result.ok then
        _on_setup_failed(validation_result.error)
        return nil
    end

    local cmds_ok, cmds = run_step(Error.Types.SETUP.INVALID_CMD, "MCPHub backend command resolution", function()
        return utils.get_default_cmds(config)
    end)
    if not cmds_ok then
        return nil
    end
    config.cmd = cmds.cmd
    config.cmdArgs = cmds.cmdArgs
    local check_ok, check_result = xpcall(function()
        return vim.system(utils.clean_args({ config.cmd, config.cmdArgs, "--version" }), { text = true }):wait()
    end, debug.traceback)
    if not check_ok or not check_result or check_result.code ~= 0 then
        return _on_setup_failed(Error("SETUP", Error.Types.SETUP.MISSING_DEPENDENCY, BACKEND_ERROR))
    end
    local installed_version = vim.trim(check_result.stdout or "")
    if installed_version ~= "4.2.1" then
        return _on_setup_failed(
            Error("SETUP", Error.Types.SETUP.VERSION_MISMATCH, "Expected project-local mcp-hub@4.2.1, found " .. tostring(installed_version) .. ". " .. BACKEND_ERROR, {
                found = installed_version,
                required = "4.2.1",
                install_cmd = INSTALL_COMMAND,
            })
        )
    end
    if not run_step(Error.Types.SETUP.INVALID_CONFIG, "MCPHub log setup", function()
        log.setup(config.log)
    end) then
        return nil
    end

    local autocmd_ok = run_step(Error.Types.SETUP.INVALID_CONFIG, "MCPHub autocmd setup", function()
        local group = vim.api.nvim_create_augroup("mcphub_cleanup", {
            clear = true,
        })
        vim.api.nvim_create_autocmd("VimLeavePre", {
            group = group,
            callback = function()
                if State.hub_instance then
                    State.hub_instance:stop()
                end
            end,
        })

        if config.workspace.enabled and config.workspace.reload_on_dir_changed then
            vim.api.nvim_create_autocmd("DirChanged", {
                group = group,
                callback = vim.schedule_wrap(function()
                    if State.hub_instance then
                        vim.defer_fn(function()
                            State.hub_instance:handle_directory_change()
                        end, 100)
                    end
                end),
            })
        end
    end)
    if not autocmd_ok then
        return nil
    end

    -- Start version check
    local ok, job = pcall(function()
        ---@diagnostic disable-next-line: missing-fields
        return Job:new({
            command = config.cmd,
            args = utils.clean_args({ config.cmdArgs, "--version" }),
            on_exit = vim.schedule_wrap(function(j, code)
                local callback_ok, callback_err = xpcall(function()
                    _handle_version_check(j, code, config)
                end, debug.traceback)
                if not callback_ok then
                    _on_setup_failed(setup_error(Error.Types.SETUP.SERVER_START, "MCPHub async setup failed: " .. tostring(callback_err)))
                end
            end),
        })
    end)

    local help_msg = BACKEND_ERROR
    if not ok then
        -- Handle executable not found error
        return _on_setup_failed(Error("SETUP", Error.Types.SETUP.MISSING_DEPENDENCY, help_msg, { stack = job }))
    end

    -- Start the job (uv.spawn might fail)
    local spawn_ok, err = pcall(job.start, job)
    if not spawn_ok then
        -- Handle spawn error
        return _on_setup_failed(
            Error(
                "SETUP",
                Error.Types.SETUP.MISSING_DEPENDENCY,
                "Failed to spawn mcp-hub process: " .. tostring(err) .. "\n\n" .. help_msg
            )
        )
    end

    return State.hub_instance
end

return M
