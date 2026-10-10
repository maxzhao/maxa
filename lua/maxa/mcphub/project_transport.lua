local Job = require("plenary.job")
local curl = require("plenary.curl")
local config_manager = require("maxa.mcphub.utils.config_manager")
local mcphub_utils = require("maxa.mcphub.utils")
local version = require("maxa.mcphub.utils.version")

local M = {}

local transports = {}
local backend_inflight = {}
local ensure_inflight = {}

local function once(callback)
    local called = false
    return function(...)
        if called then
            return
        end
        called = true
        return callback(...)
    end
end

local function base_url(context)
    return (context.server_url or string.format("http://localhost:%d", context.port)):gsub("/+$", "")
end

local function invoke_waiter(waiter, ...)
    local ok, err = pcall(waiter, ...)
    if not ok then
        vim.notify("[MCPHub] Project transport waiter failed: " .. tostring(err), vim.log.levels.ERROR)
    end
end

local function request(context, method, path, opts)
    opts = opts or {}
    local callback = once(opts.callback or function() end)
    local raw = { "--connect-timeout", "1" }
    if opts.timeout then
        vim.list_extend(raw, { "--max-time", tostring(math.max(1, math.ceil(opts.timeout / 1000))) })
    end
    local request_opts = {
        url = string.format("%s/api/%s", base_url(context), path),
        method = method,
        headers = {
            ["Content-Type"] = "application/json",
            ["Accept"] = "application/json",
        },
        raw = raw,
        callback = vim.schedule_wrap(function(response)
            local status = tonumber(response and response.status) or 0
            if status < 200 or status >= 300 then
                return callback(nil, string.format("HTTP %s from MCPHub %s", tostring(status), path))
            end
            local ok, decoded = pcall(vim.json.decode, response.body or "")
            if not ok or type(decoded) ~= "table" then
                return callback(nil, "Invalid MCPHub response for " .. path .. ": " .. tostring(decoded))
            end
            return callback(decoded, nil)
        end),
        on_error = vim.schedule_wrap(function(err)
            callback(nil, tostring(err))
        end),
    }
    if opts.body then
        request_opts.body = vim.json.encode(opts.body)
    end
    curl.request(request_opts)
end

local function find_server(health, server_name)
    for _, server in ipairs((health and health.servers) or {}) do
        if server.name == server_name then
            return server
        end
    end
    return nil
end

local function administrator_disabled_error(server_name)
    return string.format("Ability '%s' is disabled in this project; enable it in MaxaConfig > 能力", server_name)
end

local function resolve_global_env(context)
    local config = require("maxa.mcphub.config")
    local source = config.global_env
    if type(source) == "function" then
        local ok, value = pcall(source, context)
        source = ok and value or {}
    end
    if type(source) ~= "table" then
        return {}
    end
    local result = {}
    for key, value in pairs(source) do
        if type(key) == "number" and type(value) == "string" then
            local env_value = os.getenv(value)
            if env_value then
                result[value] = env_value
            end
        elseif type(key) ~= "number" and type(value) == "string" then
            result[key] = value
        end
    end
    return result
end

local function start_backend(context, callback)
    local config = require("maxa.mcphub.config")
    local workspace = require("maxa.mcphub.utils.workspace")
    if not workspace.acquire_context_port(context) then
        return callback(nil, "LEASE_CONFLICT", context.port)
    end
    local started_port = context.port
    local function release_started_lease()
        workspace.release_port(started_port, context.workspace_key)
        if context.port == started_port and context._port_lease_owner == context.workspace_key then
            context._port_lease_owner = nil
        end
    end
    local args = mcphub_utils.clean_args({ config.cmdArgs, "--port", tostring(started_port) })
    for _, config_file in ipairs(context.config_files or {}) do
        vim.list_extend(args, { "--config", config_file })
    end
    vim.list_extend(args, {
        "--auto-shutdown",
        "--shutdown-delay",
        config.shutdown_delay or 0,
        "--watch",
    })
    if config.explicit_server_activation then
        table.insert(args, "--explicit-server-activation")
    end

    local job_env, env_err = require("maxa.mcphub.utils.backend_env").build(context, config.backend_env)
    if not job_env then
        release_started_lease()
        return callback(nil, env_err, started_port)
    end
    local global_env = resolve_global_env(context)
    if next(global_env) then
        job_env.MCP_HUB_ENV = vim.json.encode(global_env)
    end

    local transport = transports[context.workspace_key] or { context = context }
    transports[context.workspace_key] = transport
    local job_opts = {
        command = config.cmd,
        args = args,
        cwd = context.cwd,
        env = job_env,
        hide = true,
        on_exit = vim.schedule_wrap(function(job, code)
            release_started_lease()
            if transport.job == job then
                transport.job = nil
            end
            if code ~= 0 then
                local stderr = table.concat(job:stderr_result() or {}, "\n")
                if stderr:match("EADDRINUSE") then
                    callback(nil, "EADDRINUSE", started_port)
                else
                    callback(nil, string.format("MCPHub backend exited with code %s: %s", tostring(code), stderr), started_port)
                end
            end
        end),
    }
    local created, job_or_err = pcall(Job.new, Job, job_opts)
    if not created then
        release_started_lease()
        return callback(nil, "Failed to create MCPHub backend Job: " .. tostring(job_or_err), started_port)
    end
    transport.job = job_or_err
    local ok, err = pcall(transport.job.start, transport.job)
    if not ok then
        release_started_lease()
        callback(nil, "Failed to start MCPHub backend: " .. tostring(err), started_port)
    end
end

local function ensure_backend(context, callback)
    local key = context.workspace_key
    if backend_inflight[key] then
        backend_inflight[key][#backend_inflight[key] + 1] = callback
        return
    end
    backend_inflight[key] = { callback }
    local function finish(health, err)
        if err then
            local transport = transports[key]
            if transport and transport.job then
                pcall(transport.job.shutdown, transport.job, 0)
                transport.job = nil
            end
            require("maxa.mcphub.utils.workspace").release_context_port(context)
        end
        local waiters = backend_inflight[key] or {}
        backend_inflight[key] = nil
        for _, waiter in ipairs(waiters) do
            invoke_waiter(waiter, health, err)
        end
    end
    finish = once(finish)
    local deadline = vim.uv.now() + (require("maxa.mcphub.config").readiness_timeout or 15000)
    local started = false
    local workspace = require("maxa.mcphub.utils.workspace")

    local function reselect_port()
        workspace.release_context_port(context)
        local existing = workspace.find_matching_workspace_hub(context.workspace_root, context.config_files)
        if existing and workspace.cache_entry_matches_context(existing, context) then
            context.port = existing.port
            context.existing_hub = existing
            context.identity_verified = true
            return true
        end
        local port = workspace.find_available_port(
            context.workspace_root,
            require("maxa.mcphub.config").workspace.port_range,
            100,
            workspace.get_port_reservations(),
            key
        )
        if not port then
            return false
        end
        context.port = port
        context.existing_hub = nil
        context.identity_verified = false
        return true
    end

    local function identity_matches()
        if context.identity_verified then
            return true
        end
        local entry = workspace.get_workspace_hub_info(context.port)
        return workspace.cache_entry_matches_context(entry, context)
    end

    local function poll()
        request(context, "GET", "health", {
            timeout = 3000,
            callback = function(health, err)
                if health then
                    if health.server_id ~= "mcp-hub" or health.status ~= "ok" then
                        return finish(nil, "Selected port is not an MCPHub backend")
                    end
                    if health.version ~= version.REQUIRED_NODE_VERSION.string then
                        return finish(nil, string.format(
                            "MCPHub backend version mismatch: expected %s, found %s",
                            version.REQUIRED_NODE_VERSION.string,
                            tostring(health.version)
                        ))
                    end
                    if require("maxa.mcphub.config").explicit_server_activation
                        and (health.explicit_server_activation ~= true
                            or (not context.server_url and health.server_disabled_retired ~= true))
                    then
                        if context.server_url then
                            return finish(nil, "Remote MCPHub endpoint does not support explicit Server activation")
                        end
                        if context._explicit_activation_restart_requested then
                            if vim.uv.now() >= deadline then
                                return finish(nil, "Timed out replacing an incompatible MCPHub backend")
                            end
                            return vim.defer_fn(poll, 100)
                        end
                        context._explicit_activation_restart_requested = true
                        request(context, "POST", "hard-restart", {
                            timeout = 3000,
                            callback = function(_, restart_err)
                                if restart_err then
                                    return finish(nil, "Failed to replace incompatible MCPHub backend: " .. tostring(restart_err))
                                end
                                context.existing_hub = nil
                                context.identity_verified = false
                                vim.defer_fn(poll, 100)
                            end,
                        })
                        return
                    end
                    if not identity_matches() then
                        if vim.uv.now() >= deadline or not reselect_port() then
                            return finish(nil, "MCPHub backend workspace/config identity mismatch")
                        end
                        started = false
                        return vim.defer_fn(poll, 10)
                    end
                    return finish(health, nil)
                end
                if context.server_url then
                    return finish(nil, "Remote MCPHub endpoint is unavailable: " .. tostring(err))
                end
                if vim.uv.now() >= deadline then
                    return finish(nil, "Timed out waiting for project MCPHub backend: " .. tostring(err))
                end
                if not started then
                    started = true
                    start_backend(context, function(_, start_err, started_port)
                        if context.port ~= started_port then
                            return
                        end
                        if start_err == "EADDRINUSE" or start_err == "LEASE_CONFLICT" then
                            if not reselect_port() then
                                return finish(nil, "No available port after MCPHub backend address collision")
                            end
                            started = false
                        elseif start_err then
                            finish(nil, start_err)
                        end
                    end)
                end
                vim.defer_fn(poll, 100)
            end,
        })
    end

    poll()
end

---Resolve exact-cwd workspace transport provenance without changing UI Hub state.
---@param cwd string
---@return table|nil
---@return string|nil
function M.resolve(cwd)
    local catalog, err = config_manager.get_effective_catalog(cwd)
    if not catalog then
        return nil, err
    end
    local mcphub = require("maxa.mcphub")
    local context, context_err
    if type(mcphub.resolve_project_context) == "function" then
        context, context_err = mcphub.resolve_project_context(cwd)
    else
        local hub = type(mcphub.get_hub_instance) == "function" and mcphub.get_hub_instance() or nil
        if hub and type(hub.resolve_project_context) == "function" then
            context, context_err = hub:resolve_project_context(cwd)
        end
    end
    if not context then
        return nil, context_err or ("Failed to resolve MCPHub workspace for " .. tostring(cwd))
    end
    context.workspace_key = context.workspace_key or catalog.workspace_key
    context.config_files = context.config_files or catalog.context.config_files
    context.workspace_root = context.workspace_root or catalog.context.workspace_root
    context.cwd = context.cwd or catalog.context.cwd
    local workspace = require("maxa.mcphub.utils.workspace")
    if context.existing_hub and workspace.cache_entry_matches_context(context.existing_hub, context) then
        context.identity_verified = true
    end
    local config_files = {}
    for _, path in ipairs(context.config_files or {}) do
        config_files[#config_files + 1] = workspace.normalize_path(path)
    end
    return {
        context = context,
        workspace_key = context.workspace_key,
        workspace_root = workspace.normalize_path(context.workspace_root),
        config_files = config_files,
        catalog = catalog,
    }, nil
end

---Ensure a configured Server is connected for the explicit cwd.
---@param cwd string
---@param server_name string
---@param callback fun(server: table|nil, err: string|nil, resolved: table|nil)
function M.ensure_server(cwd, server_name, callback)
    local resolved, resolve_err = M.resolve(cwd)
    if not resolved then
        return callback(nil, resolve_err, nil)
    end
    local configured = resolved.catalog.servers[server_name]
    if not configured then
        return callback(nil, string.format("Server '%s' is not configured for %s", server_name, cwd), resolved)
    end
    if config_manager.is_server_disabled(resolved.catalog, server_name) then
        return callback(nil, administrator_disabled_error(server_name, configured), resolved)
    end

    local key = resolved.workspace_key .. "\0" .. server_name
    if ensure_inflight[key] then
        table.insert(ensure_inflight[key], callback)
        return
    end
    ensure_inflight[key] = { callback }
    local function finish(server, err)
        if server then
            local allowed, policy_err = require("maxa.project.settings").check_ability(resolved.catalog.project_root or cwd, server_name)
            if not allowed then server, err = nil, policy_err end
        end
        local waiters = ensure_inflight[key] or {}
        ensure_inflight[key] = nil
        for _, waiter in ipairs(waiters) do
            invoke_waiter(waiter, server, err, resolved)
        end
    end

    local mcphub = require("maxa.mcphub")
    local native_server = configured.is_native and mcphub.is_native_server(server_name) or nil
    if native_server then
        local ok, start_err = pcall(function()
            if native_server.status ~= "connected" then
                native_server:start()
            end
        end)
        if not ok or native_server.status ~= "connected" then
            return finish(nil, ok and ("Native Server status is " .. tostring(native_server.status)) or tostring(start_err))
        end
        return finish(native_server, nil)
    end

    ensure_backend(resolved.context, function(health, backend_err)
        if not health then
            return finish(nil, backend_err)
        end
        local allowed, policy_err = require("maxa.project.settings").check_ability(resolved.catalog.project_root or cwd, server_name)
        if not allowed then return finish(nil, policy_err) end
        local server = find_server(health, server_name)
        if server and server.status == "connected" then
            return finish(server, nil)
        end
        request(resolved.context, "POST", "servers/start", {
            timeout = require("maxa.mcphub.config").mcp_request_timeout or 60000,
            body = { server_name = server_name },
            callback = function(response, start_err)
                if not response then
                    return finish(nil, "Failed to start Server '" .. server_name .. "': " .. tostring(start_err))
                end
                local started_server = response.server or find_server(response, server_name)
                if not started_server then
                    return finish(nil, "Server '" .. server_name .. "' started but returned no Server metadata")
                end
                if started_server.status ~= "connected" then
                    return finish(
                        nil,
                        string.format(
                            "Server '%s' start returned non-connected status '%s'",
                            server_name,
                            tostring(started_server.status)
                        )
                    )
                end
                finish(started_server, nil)
            end,
        })
    end)
end

---Inspect one configured Server without starting a backend or Server.
---@param cwd string
---@param server_name string
---@param callback fun(state: table|nil, err: string|nil, resolved: table|nil)
function M.inspect_server(cwd, server_name, callback)
    local resolved, resolve_err = M.resolve(cwd)
    if not resolved then
        return callback(nil, resolve_err, nil)
    end
    local configured = resolved.catalog.servers[server_name]
    if not configured then
        return callback(nil, string.format("Server '%s' is not configured for %s", server_name, cwd), resolved)
    end
    if config_manager.is_server_disabled(resolved.catalog, server_name) then
        return callback({
            name = server_name,
            configured = true,
            disabled = true,
            connected = false,
            status = "disabled",
        }, nil, resolved)
    end

    local mcphub = require("maxa.mcphub")
    local native_server = configured.is_native and mcphub.is_native_server(server_name) or nil
    if native_server then
        return callback({
            name = server_name,
            configured = true,
            disabled = false,
            connected = native_server.status == "connected",
            status = native_server.status or "disconnected",
            server = native_server,
        }, nil, resolved)
    end

    local context = resolved.context
    local workspace = require("maxa.mcphub.utils.workspace")
    local existing = context.existing_hub
    if not context.identity_verified then
        if not (existing and workspace.cache_entry_matches_context(existing, context)) then
            existing = workspace.find_matching_workspace_hub(context.workspace_root, context.config_files)
        end
        if not existing or not workspace.cache_entry_matches_context(existing, context) then
            return callback({
                name = server_name,
                configured = true,
                disabled = false,
                connected = false,
                status = "not_loaded",
            }, nil, resolved)
        end
        context.port = existing.port
        context.existing_hub = existing
        context.identity_verified = true
    end

    request(context, "GET", "health", {
        timeout = 3000,
        callback = function(health, health_err)
            if not health then
                return callback({
                    name = server_name,
                    configured = true,
                    disabled = false,
                    connected = false,
                    status = "unavailable",
                    detail = health_err,
                }, nil, resolved)
            end
            if require("maxa.mcphub.config").explicit_server_activation
                and (health.explicit_server_activation ~= true
                    or (not context.server_url and health.server_disabled_retired ~= true))
            then
                return callback({
                    name = server_name,
                    configured = true,
                    disabled = false,
                    connected = false,
                    status = "incompatible_backend",
                }, nil, resolved)
            end
            local server = find_server(health, server_name)
            return callback({
                name = server_name,
                configured = true,
                disabled = false,
                connected = server ~= nil and server.status == "connected",
                status = server and server.status or "not_loaded",
                server = server,
            }, nil, resolved)
        end,
    })
end

---Dispatch through the exact-cwd project transport. Authorization is owned by Chat.
---@param cwd string
---@param server_name string
---@param tool_name string
---@param arguments table
---@param opts table
function M.call_tool(cwd, server_name, tool_name, arguments, opts)
    opts = opts or {}
    local callback = opts.callback or function() end
    local resolved, err = M.resolve(cwd)
    if not resolved then
        return callback(nil, err)
    end
    local configured = resolved.catalog.servers[server_name]
    if not configured then
        return callback(nil, string.format("Server '%s' is not configured for %s", server_name, cwd))
    end
    if config_manager.is_server_disabled(resolved.catalog, server_name) then
        return callback(nil, administrator_disabled_error(server_name, configured))
    end
    local native_server = configured.is_native and require("maxa.mcphub").is_native_server(server_name) or nil
    if native_server and native_server.status ~= "connected" then
        return callback(nil, string.format("MCP Server '%s' is not currently loaded", server_name))
    end
    mcphub_utils.fire("MCPHubToolStart", { server = server_name, tool = tool_name })
    local function finish(result, call_err)
        mcphub_utils.fire("MCPHubToolEnd", {
            server = server_name,
            tool = tool_name,
            response = result,
            success = call_err == nil,
        })
        callback(result, call_err)
    end
    if native_server then
        return native_server:call_tool(tool_name, arguments, vim.tbl_extend("force", opts, { callback = finish }))
    end
    request(resolved.context, "POST", "servers/tools", {
        timeout = (require("maxa.mcphub.config").mcp_request_timeout or 60000) + 5000,
        body = {
            server_name = server_name,
            tool = tool_name,
            arguments = arguments or vim.empty_dict(),
            request_options = { timeout = require("maxa.mcphub.config").mcp_request_timeout or 60000 },
        },
        callback = finish,
    })
end

---Access one concrete resource through the exact-cwd project transport.
---This never starts or reconnects a Server; Chat owns authorization.
---@param cwd string
---@param server_name string
---@param uri string
---@param opts table
function M.access_resource(cwd, server_name, uri, opts)
    opts = opts or {}
    local callback = opts.callback or function() end
    local resolved, err = M.resolve(cwd)
    if not resolved then
        return callback(nil, err)
    end
    local configured = resolved.catalog.servers[server_name]
    if not configured then
        return callback(nil, string.format("Server '%s' is not configured for %s", server_name, cwd))
    end
    if config_manager.is_server_disabled(resolved.catalog, server_name) then
        return callback(nil, administrator_disabled_error(server_name, configured))
    end
    local native_server = configured.is_native and require("maxa.mcphub").is_native_server(server_name) or nil
    if native_server then
        if native_server.status ~= "connected" then
            return callback(nil, string.format("MCP Server '%s' is not currently loaded", server_name))
        end
        return native_server:access_resource(uri, vim.tbl_extend("force", opts, { callback = callback }))
    end
    return M.inspect_server(cwd, server_name, function(state, inspect_err, inspected)
        if opts.project_root then
            local allowed, policy_err = require("maxa.project.settings").check_ability(opts.project_root, server_name)
            if not allowed then return callback(nil, policy_err) end
        end
        if not state then
            return callback(nil, inspect_err)
        end
        if not state.connected then
            return callback(nil, string.format("MCP Server '%s' is not currently loaded", server_name))
        end
        request(inspected.context, "POST", "servers/resources", {
            timeout = (require("maxa.mcphub.config").mcp_request_timeout or 60000) + 5000,
            body = {
                server_name = server_name,
                uri = uri,
                request_options = { timeout = require("maxa.mcphub.config").mcp_request_timeout or 60000 },
            },
            callback = callback,
        })
    end)
end

function M._reset_for_tests()
    transports = {}
    backend_inflight = {}
    ensure_inflight = {}
    require("maxa.mcphub.utils.workspace")._reset_port_reservations_for_tests()
end

return M
