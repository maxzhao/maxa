local Error = require("maxa.mcphub.utils.errors")
local Job = require("plenary.job")
local State = require("maxa.mcphub.state")
local config = require("maxa.mcphub.config")
local config_manager = require("maxa.mcphub.utils.config_manager")
local constants = require("maxa.mcphub.utils.constants")
local curl = require("plenary.curl")
local version = require("maxa.mcphub.utils.version")
local workspace_utils = require("maxa.mcphub.utils.workspace")

local handlers = require("maxa.mcphub.utils.handlers")
local log = require("maxa.mcphub.utils.log")
local native = require("maxa.mcphub.native")
local prompt_utils = require("maxa.mcphub.utils.prompt")
local utils = require("maxa.mcphub.utils")

-- Default timeouts
local CONNECT_TIMEOUT = 1000 -- 1s for curl to connect to localhost
local TOOL_TIMEOUT = 60000 -- 60s for tool calls
local RESOURCE_TIMEOUT = 60000 -- 60s for resource access
local PROMPT_TIMEOUT = 60000 -- 60s for tool calls
local MCP_REQUEST_TIMEOUT = 60000 -- 60s for MCP requests

--- @class MCPHub.Hub
--- @field port number The port number for the MCP Hub server
--- @field server_url string In case of hosting mcp-hub somewhere, the url with `https://mydomain.com:5858`
--- @field config string Path to the MCP servers configuration file
--- @field explicit_server_activation boolean whether configured capability Servers wait for explicit start
--- @field shutdown_delay number Delay in seconds before shutting down the server
--- @field cmd string The cmd to invoke the MCP Hub server
--- @field cmdArgs table The args to pass to the cmd to spawn the server
--- @field readiness_timeout number Maximum time allowed for initial setup to reach readiness in milliseconds
--- @field ready boolean Whether the connection to server is ready
--- @field server_job Job|nil The server process job if we started it
--- @field is_owner boolean Whether this instance started the server
--- @field is_shutting_down boolean Whether we're in the process of shutting down
---@field mcp_request_timeout number --Max time allowed for a MCP tool or resource to execute in milliseconds, set longer for long running tasks
---@field on_ready fun(hub)
--- @field on_error fun(error:string)
--- @field setup_opts table Original options used to create this hub instance
local MCPHub = {}
MCPHub.__index = MCPHub

--- Create a new MCPHub instance
--- @param opts table Configuration options
--- @return MCPHub.Hub
function MCPHub:new(opts)
    local instance = setmetatable({
        port = opts.port,
        server_url = opts.server_url,
        config = opts.config,
        explicit_server_activation = opts.explicit_server_activation == true,
        shutdown_delay = opts.shutdown_delay,
        cmd = opts.cmd,
        cmdArgs = opts.cmdArgs,
        ready = false,
        server_job = nil,
        is_owner = false,
        is_shutting_down = false,
        is_starting = false,
        mcp_request_timeout = opts.mcp_request_timeout or MCP_REQUEST_TIMEOUT,
        readiness_timeout = opts.readiness_timeout,
        on_ready = opts.on_ready or function() end,
        on_error = opts.on_error or function() end,
        setup_opts = opts,
    }, MCPHub)

    -- Setup global state tracking
    instance:_setup_global_state_tracking()

    return instance
end

--- Resolve context (workspace vs global) for an explicit directory.
--- @param cwd? string Defaults to the process cwd for the process-global UI Hub.
--- @return MCPHub.JobContext|nil Context information or nil on error
function MCPHub:resolve_context(cwd)
    cwd = cwd or vim.fn.getcwd()
    if not State.config.workspace.enabled then
        return self:_resolve_global_context(cwd)
    end

    return self:_resolve_workspace_context(cwd)
end

--- Resolve workspace-specific context
--- @param cwd string
--- @return MCPHub.JobContext|nil Workspace context or nil to fall back to global
function MCPHub:_resolve_workspace_context(cwd)

    -- Find workspace config
    local workspace_info = workspace_utils.find_workspace_config(State.config.workspace.look_for, cwd)

    if not workspace_info then
        -- No workspace config found, fall back to global mode
        log.debug("No workspace config found, falling back to global mode")
        return self:_resolve_global_context(cwd)
    end

    log.debug("Found workspace config" .. vim.inspect(workspace_info))

    local port

    -- Prepare config files (order matters: global first, then project)
    local global_config = self.config -- Original global config path
    local project_config = workspace_info.config_file
    local config_files = { global_config, project_config }
    local workspace_key = workspace_utils.workspace_key({
        workspace_root = workspace_info.root_dir or cwd,
        config_files = config_files,
    })

    -- Check for existing hub using root and config_file because using hashed port might not be reliable when we found next available port if a port is occupied
    local existing_hub = workspace_utils.find_matching_workspace_hub(workspace_info.root_dir, config_files)
    if existing_hub then
        port = existing_hub.port
        log.debug("Found existing workspace hub" .. vim.inspect({
            workspace_root = workspace_info.root_dir,
            port = port,
            pid = existing_hub.pid,
        }))
    else
        if State.config.workspace.get_port and type(State.config.workspace.get_port) == "function" then
            -- Use custom port function if provided
            port = State.config.workspace.get_port()
            if not port or type(port) ~= "number" then
                vim.notify("Invalid port returned by workspace.get_port function", vim.log.levels.ERROR)
                return nil
            end
            log.debug("Using custom port from workspace.get_port: " .. port)
        else
            -- Generate new port
            port = workspace_utils.find_available_port(
                workspace_info.root_dir,
                State.config.workspace.port_range,
                100, -- max attempts
                workspace_utils.get_port_reservations(),
                workspace_key
            )
        end

        if not port then
            vim.notify("No available unreserved port for workspace hub", vim.log.levels.ERROR)
            return nil
        end

        log.debug("Generated new port for workspace" .. vim.inspect({
            workspace_root = workspace_info.root_dir,
            port = port,
        }))
    end

    return {
        port = port,
        cwd = workspace_info.root_dir or cwd,
        config_files = config_files,
        is_workspace_mode = true,
        workspace_root = workspace_info.root_dir or cwd,
        workspace_key = workspace_key,
        existing_hub = existing_hub, -- Include hub info from cache
    }
end

--- Resolve global context (original behavior)
--- @param cwd string
--- @return MCPHub.JobContext Global context
function MCPHub:_resolve_global_context(cwd)
    local port = self.setup_opts.port
    -- For global mode, port will always be the one provided in setup_opts, so we can get the existing hub using that
    local existing_hub = workspace_utils.get_workspace_hub_info(port)
    return {
        port = port,
        cwd = cwd,
        config_files = { self.config },
        is_workspace_mode = false,
        workspace_root = cwd,
        existing_hub = existing_hub,
    }
end

---Resolve a Chat-targeted context without mutating process-global Hub state.
---@param cwd string
---@return MCPHub.JobContext|nil
function MCPHub:resolve_project_context(cwd)
    if type(cwd) ~= "string" or vim.trim(cwd) == "" then
        return nil, "explicit cwd is required"
    end
    local context = self:resolve_context(cwd)
    if not context then
        return nil, "Failed to resolve MCPHub workspace for " .. tostring(cwd)
    end

    context.workspace_key = workspace_utils.workspace_key(context)
    local ui_context = State.current_hub
    if ui_context and ui_context.port and workspace_utils.workspace_key(ui_context) == context.workspace_key then
        context.port = ui_context.port
        context.server_url = self.server_url
        context.identity_verified = true
        context.existing_hub = ui_context.existing_hub or context.existing_hub
        return context
    end

    if self.server_url then
        return nil,
            string.format(
                "Remote MCPHub endpoint %s represents the process-global UI workspace and cannot route exact workspace %s",
                self.server_url,
                context.workspace_key
            )
    end

    -- Global config still needs an independent backend when the exact Chat cwd is
    -- not the UI Hub cwd. Treat it as an ordinary project lease instead of
    -- routing through the fixed process-global port.
    if not context.is_workspace_mode then
        local existing = workspace_utils.find_matching_workspace_hub(context.workspace_root, context.config_files)
        if existing then
            context.port = existing.port
            context.existing_hub = existing
        else
            context.port = workspace_utils.find_available_port(
                context.workspace_root,
                State.config.workspace.port_range,
                100,
                workspace_utils.get_port_reservations(),
                context.workspace_key
            )
            context.existing_hub = nil
        end
        if not context.port then
            return nil
        end
    end
    return context
end

--- Resolve global environment variables
--- @param context MCPHub.JobContext Hub context (workspace info, port, etc.)
--- @return table Resolved global environment variables
function MCPHub:_resolve_global_env(context)
    local global_env_config = config.global_env
    local resolved_global_env = {}

    -- Handle function type
    if type(global_env_config) == "function" then
        local success, result = pcall(global_env_config, context)
        if not success then
            vim.notify("global_env function failed: " .. result, vim.log.levels.WARN)
            return {}
        end
        if type(result) ~= "table" then
            vim.notify("global_env function must return a table", vim.log.levels.WARN)
            return {}
        end
        global_env_config = result
    elseif type(global_env_config) ~= "table" then
        if global_env_config ~= nil then
            vim.notify("global_env must be table or function", vim.log.levels.WARN)
        end
        return {}
    end

    -- Process mixed array/hash format
    for key, value in pairs(global_env_config) do
        if type(key) == "number" then
            -- Array-style entry: just the env var name
            if type(value) == "string" then
                local env_value = os.getenv(value)
                if env_value then
                    resolved_global_env[value] = env_value
                end
            end
        else
            -- Hash-style entry: key = value
            if type(value) == "string" then
                resolved_global_env[key] = value
            end
        end
    end

    return resolved_global_env
end

--- Start server with resolved context
--- @param context MCPHub.JobContext Context information from resolve_context
function MCPHub:_start_server_with_context(context)
    if not workspace_utils.acquire_context_port(context) and context.is_workspace_mode then
        context.port = workspace_utils.find_available_port(
            context.workspace_root,
            State.config.workspace.port_range,
            100,
            workspace_utils.get_port_reservations(),
            context.workspace_key
        )
        context.existing_hub = nil
    end
    if not workspace_utils.acquire_context_port(context) then
        self:handle_hub_stopped("Failed to acquire MCPHub workspace port lease")
        return
    end
    self.port = context.port
    self.is_owner = true
    if self.server_job then
        self.server_job = nil
    end

    -- Resolve global environment variables
    local resolved_global_env = self:_resolve_global_env(context)

    -- Build command args with config files
    local args = utils.clean_args({
        self.cmdArgs,
        "--port",
        tostring(context.port),
    })

    -- Add all config files (global first, then project-specific)
    for _, config_file in ipairs(context.config_files) do
        table.insert(args, "--config")
        table.insert(args, config_file)
    end

    -- Add other flags
    vim.list_extend(args, {
        "--auto-shutdown",
        "--shutdown-delay",
        self.shutdown_delay or 0,
        "--watch",
    })
    if self.explicit_server_activation then
        table.insert(args, "--explicit-server-activation")
    end

    -- Backend-only values remain outside the global environment broadcast.
    local job_env, env_err = require("maxa.mcphub.utils.backend_env").build(context, config.backend_env)
    if not job_env then
        self:handle_hub_stopped(env_err)
        return
    end
    if next(resolved_global_env) then
        -- Serialize global env for mcp-hub
        local success, json_env = pcall(vim.fn.json_encode, resolved_global_env)
        if success then
            job_env.MCP_HUB_ENV = json_env
            log.debug("Passing global environment variables to mcp-hub: " .. vim.inspect({
                count = vim.tbl_count(resolved_global_env),
                keys = vim.tbl_keys(resolved_global_env),
            }))
        else
            vim.notify("Failed to serialize global_env: " .. json_env, vim.log.levels.WARN)
        end
    end

    log.debug("Starting server with context" .. vim.inspect({
        port = context.port,
        cwd = context.cwd,
        config_files = context.config_files,
        is_workspace_mode = context.is_workspace_mode,
    }))

    ---@diagnostic disable-next-line: missing-fields
    local job_opts = {
        command = self.cmd,
        args = args,
        cwd = context.cwd, -- Set working directory
        env = job_env, -- Pass environment variables
        hide = true,
        on_stderr = vim.schedule_wrap(function(_, data)
            if data then
                log.debug("Server stderr:" .. data)
            end
        end),
        on_start = vim.schedule_wrap(function()
            self:connect_sse()
        end),
        on_stdout = vim.schedule_wrap(function(_, _)
            -- if data then
            --     log.debug("Server stdout:" .. data)
            -- end
        end),
        on_exit = vim.schedule_wrap(function(j, code)
            workspace_utils.release_context_port(context)
            local stderr = table.concat(j:stderr_result() or {}, "\n")
            log.debug("Server process exited with code " .. code .. " and stderr: " .. stderr)
            if stderr:match("EADDRINUSE") then
                -- Keep connecting: another compatible hub may own the selected port.
                log.debug("Port taken, trying to connect...")
            elseif code ~= 0 then
                local message = "Server process exited with code " .. tostring(code)
                if stderr ~= "" then
                    message = message .. ": " .. stderr
                end
                self:handle_hub_stopped(message, code, j)
            end
        end),
    }
    local created, job_or_err = pcall(Job.new, Job, job_opts)
    if not created then
        workspace_utils.release_context_port(context)
        self:handle_hub_stopped("Failed to create MCPHub backend Job: " .. tostring(job_or_err), 1)
        return
    end
    self.server_job = job_or_err

    local started, start_err = pcall(self.server_job.start, self.server_job)
    if not started then
        workspace_utils.release_context_port(context)
        self.server_job = nil
        self:handle_hub_stopped("Failed to start MCPHub backend: " .. tostring(start_err), 1)
    end
end

--- Start the MCP Hub server
function MCPHub:start()
    if self.is_starting then
        vim.notify("MCP Hub is starting", vim.log.levels.WARN)
        return
    end
    log.debug("Starting hub")
    State:clear_logs()
    -- Update state
    State:update_hub_state(constants.HubState.STARTING)
    self.is_restarting = false
    self.is_starting = true

    -- Resolve context (workspace vs global)
    local context = self:resolve_context()
    if not context then
        self:handle_hub_stopped("Failed to resolve hub context")
        return
    end

    -- Update state with resolved context
    State.current_hub = context
    self.port = context.port -- Update our port for this session

    -- Load config cache into state
    local cache_loaded, refresh_err = config_manager.refresh_config()
    if not cache_loaded then
        self:handle_hub_stopped("Failed to load MCP servers configuration:" .. (refresh_err or ""))
        return
    end
    log.debug("Resolved hub context: " .. vim.inspect(context))

    -- Make sure to load after the config is refreshed to avoid double reading of config files
    native.setup(config.native_servers)
    self:fire_servers_updated()

    -- Step 3: Check if server is already running on the resolved port and is of same version in cases of plugin updated
    self:check_server(function(is_running, is_our_server, is_same_version, activation_compatible)
        if is_running then
            if not is_our_server then
                self:handle_hub_stopped("Port in use by non-MCP Hub server")
                return
            end
            if not is_same_version or not activation_compatible then
                local reason = not is_same_version and "version mismatch" or "activation mode mismatch"
                log.debug("Existing server has " .. reason .. ", restarting")
                vim.notify("mcp-hub " .. reason .. ". Restarting hub...", vim.log.levels.INFO)
                self:handle_same_port_different_config(context)
                return
            end
            if not context.existing_hub then
                log.debug(
                    "Port available but no existing hub info, might be due to changed config files, starting new server"
                )
                self:handle_same_port_different_config(context)
                return
            end

            -- Check config compatibility using cached hub info
            if context.existing_hub and context.existing_hub.config_files then
                local config_matches = vim.deep_equal(context.existing_hub.config_files, context.config_files)
                if config_matches then
                    log.debug("Config files match, connecting to existing server")
                    self:connect_sse()
                else
                    log.debug("Config files changed, restarting server")
                    vim.notify("Config files changed. Restarting hub...", vim.log.levels.INFO)
                    self:handle_same_port_different_config(context)
                end
            else
                -- No config info available (backwards compatibility)
                log.debug("No config info in cache, connecting to existing server")
                self:connect_sse()
            end
            return
        end

        -- Step 4: Start new server with resolved context
        self:_start_server_with_context(context)
    end)
end

--- Handle directory changes - reconnect to appropriate workspace hub
function MCPHub:handle_directory_change()
    if not State.config.workspace.enabled then
        return
    end

    log.debug("Directory changed, checking if workspace hub should change")

    -- Resolve new context for current directory
    local new_context = self:resolve_context()
    if not new_context then
        log.warn("Failed to resolve context after directory change")
        return
    end

    -- Compare with current context
    local current_context = State.current_hub
    if not current_context then
        log.debug("No current hub context, starting new hub")
        self:start()
        return
    end

    -- Check if we need to switch hubs
    local needs_switch = false
    local reason = ""

    if tostring(new_context.port) ~= tostring(current_context.port) then
        needs_switch = true
        reason = string.format("port change (%s -> %s)", current_context.port, new_context.port)
    end

    if needs_switch then
        log.debug("Switching hub due to: " .. reason)
        -- self:restart(nil, reason)
        workspace_utils.release_context_port(current_context)
        self:stop_sse()
        vim.schedule(function()
            self:start()
        end)
    else
        log.debug("No hub switch needed - context unchanged")
    end
end

function MCPHub:handle_hub_ready()
    if self._setup_disposed then
        return
    end
    self.ready = true
    self.is_restarting = false
    self.is_starting = false
    self:_update_global_state()
    if self._on_setup_ready then
        self._on_setup_ready(self)
    else
        self.on_ready(self)
    end
    if not self.ready or self._setup_disposed then
        return
    end
    self:update_servers()
end

function MCPHub:_clean_up()
    local current = State.current_hub
    workspace_utils.release_context_port(current)
    self.is_owner = false
    self.ready = false
    self.is_starting = false
    self.is_restarting = false
    if self.server_job then
        pcall(self.server_job.shutdown, self.server_job, 0)
        self.server_job = nil
    end
    self:stop_sse()
    State:update_hub_state(constants.HubState.STOPPED)
    self:_update_global_state()
end

---@param msg string
---@param code number|nil
function MCPHub:handle_hub_stopped(msg, code, server_job)
    if self._setup_disposed then
        return
    end
    if server_job then
        -- While changing directories, we might have to start a new job for that directory
        -- Once in the new directory, if the old directory's job stops for any reason for e.g (shutdown_delay reached)
        -- handle_hub_stopped will be called which causes the hub UI to show as stopped.
        -- Therefore, we need to check if the server_job is the same as the one that called this function
        if self.server_job ~= server_job then
            return
        end
    end
    code = code ~= nil and code or 1
    -- if self.is_shutting_down then
    --     return -- Skip error handling during shutdown
    -- end
    if code ~= 0 then
        if self._on_setup_failed and State.setup_state == "in_progress" then
            self._on_setup_failed(Error("SETUP", Error.Types.SETUP.SERVER_START, msg))
            return
        end
        -- Create error object
        local err = Error("SERVER", Error.Types.SERVER.SERVER_START, msg)
        State:add_error(err)
        self.on_error(tostring(err))
    end
    self:_clean_up()
end

--- Check if server is running and handle connection
--- @param callback fun(is_running:boolean, is_our_server:boolean, is_same_version:boolean, activation_compatible:boolean) Callback function to handle the result
function MCPHub:check_server(callback)
    log.debug("Checking Server")
    if self:is_ready() then
        return callback(true, true, true, true)
    end
    -- Quick health check
    local opts = {
        timeout = 3000,
        skip_ready_check = true,
    }

    opts.callback = function(response, err)
        local callback_ok, callback_err = xpcall(function()
            if err then
                log.debug("Error while get health in check_server")
                callback(false, false, false, false)
            else
                local is_hub_server = response and response.server_id == "mcp-hub" and response.status == "ok"
                local is_same_version = response and response.version == version.REQUIRED_NODE_VERSION.string
                local activation_compatible = not self.explicit_server_activation
                    or (response.explicit_server_activation == true
                        and (self.server_url or response.server_disabled_retired == true))
                log.debug(
                    string.format(
                        "Got health response in check_server, is_hub_server (%s), is_same_version (%s) ",
                        tostring(is_hub_server),
                        tostring(is_same_version)
                    )
                )
                callback(true, is_hub_server, is_same_version, activation_compatible) -- Running but may not be compatible
            end
        end, debug.traceback)
        if not callback_ok then
            self:handle_hub_stopped("MCPHub asynchronous setup callback failed: " .. tostring(callback_err))
        end
    end
    return self:get_health(opts)
end

--- Get server status information
--- @param opts? { callback?: fun(response: table?, error: string?) } Optional callback(response: table|nil, error?: string)
--- @return table|nil, string|nil If no callback is provided, returns response and error
function MCPHub:get_health(opts)
    return self:api_request("GET", "health", opts)
end

---@param name string
---@return NativeServer | MCPServer | nil
function MCPHub:get_server(name)
    local is_native = native.is_native_server(name)
    if is_native then
        return is_native
    end
    for _, server in ipairs(State.server_state.servers) do
        if server.name == name then
            return server
        end
    end
    return nil
end

---@param url string The OAuth callback URL
function MCPHub:handle_oauth_callback(url, callback)
    if not url or vim.trim(url) == "" then
        return vim.notify("No OAuth callback URL provided", vim.log.levels.ERROR)
    end
    self:api_request("POST", "oauth/manual_callback", {
        body = {
            url = url,
        },
        callback = callback,
    })
end

---@param name any
---@param _ any
function MCPHub:authorize_mcp_server(name, _)
    -- local authUrl = self:get_server(name)["authorizationUrl"]
    self:api_request("POST", "servers/authorize", {
        body = {
            server_name = name,
        },
        callback = function(response, _)
            --Errors will be handled automatically
            if response and response.authorizationUrl then
                vim.notify("Opening Authorization URL: " .. response.authorizationUrl, vim.log.levels.INFO)
            else
                vim.notify("No Authorization URL found for server: " .. name, vim.log.levels.WARN)
            end
        end,
    })
end

local function current_effective_catalog()
    local cwd = State.current_hub and State.current_hub.cwd or vim.fn.getcwd()
    return config_manager.get_effective_catalog(cwd)
end

local function check_project_server(name, opts)
    local cwd = State.current_hub and State.current_hub.cwd or vim.fn.getcwd()
    local settings = require("maxa.project.settings")
    local root = settings.project_root(vim.fs.root(cwd, { ".maxa", ".git", ".svn", ".hg" }) or cwd)
    local allowed, err = settings.check_ability(root, name)
    if not allowed and opts and opts.callback then opts.callback(nil, err) end
    return allowed, err
end

local function disabled_server_error(name)
    return string.format("Ability '%s' is disabled in this project; enable it in MaxaConfig > 能力", name)
end

--- Start a disconnected MCP server without changing administrator policy.
---@param name string Server name to start
---@param opts? { via_curl_request?:boolean,callback?: function }
---@return table?, string? If no callback is provided, returns response and error
function MCPHub:start_mcp_server(name, opts)
    opts = opts or {}
    local native_server = native.is_native_server(name)
    local catalog, catalog_err = current_effective_catalog()
    local configured = catalog and catalog.servers[name]
    if not configured then
        local err = catalog_err or string.format("Server '%s' is not configured in the current workspace", name)
        if opts.callback then
            opts.callback(nil, err)
            return
        end
        return nil, err
    end
    if config_manager.is_server_disabled(catalog, name) then
        local err = disabled_server_error(name, configured)
        if opts.callback then
            opts.callback(nil, err)
            return
        end
        return nil, err
    end

    if native_server then
        native_server:start()
        State:emit("servers_updated", { hub = self })
        local response = { server = native_server }
        if opts.callback then
            opts.callback(response, nil)
            return
        end
        return response, nil
    end

    for i, server in ipairs(State.server_state.servers) do
        if server.name == name then
            State.server_state.servers[i].status = "connecting"
            break
        end
    end
    State:notify_subscribers({ server_state = true }, "server")

    local request_opts = {
        body = { server_name = name },
    }
    if opts.callback then
        request_opts.callback = function(response, err)
            self:refresh()
            opts.callback(response, err)
        end
        self:api_request("POST", "servers/start", request_opts)
        return
    end
    local response, err = self:api_request("POST", "servers/start", request_opts)
    self:refresh()
    return response, err
end

--- Stop an MCP server without persisting connection state.
---@param name string Server name to stop
---@param _disable boolean Retained compatibility argument; administrator policy is config-owned
---@param opts? { via_curl_request?: boolean, callback?: function } Optional callback(response: table|nil, error?: string)
---@return table|nil, string|nil If no callback is provided, returns response and error
function MCPHub:stop_mcp_server(name, _disable, opts)
    opts = opts or {}
    local native_server = native.is_native_server(name)
    if native_server then
        native_server:stop()
        State:emit("servers_updated", { hub = self })
        local response = { server = native_server }
        if opts.callback then
            opts.callback(response, nil)
            return
        end
        return response, nil
    end

    for i, server in ipairs(State.server_state.servers) do
        if server.name == name then
            State.server_state.servers[i].status = "disconnecting"
            break
        end
    end
    State:notify_subscribers({ server_state = true }, "server")

    local request_opts = {
        body = { server_name = name },
    }
    if opts.callback then
        request_opts.callback = function(response, err)
            self:refresh()
            opts.callback(response, err)
        end
        self:api_request("POST", "servers/stop", request_opts)
        return
    end
    local response, err = self:api_request("POST", "servers/stop", request_opts)
    self:refresh()
    return response, err
end

--- Get a prompt from the server
--- @param server_name string
--- @param prompt_name string
--- @param args table
--- @param opts? {parse_response?: boolean, callback?: fun(res: MCPResponseOutput? ,err: string?), request_options?: MCPRequestOptions, timeout?: number } Optional callback(response: table|nil, error?: string) and timeout in ms (default 60s)
--- @return {messages : {role:"user"| "assistant"|"system", output: MCPResponseOutput}[]}|nil, string|nil If no callback is provided, returns response and error
function MCPHub:get_prompt(server_name, prompt_name, args, opts)
    opts = opts or {}
    local allowed, policy_err = check_project_server(server_name, opts)
    if not allowed then return nil, policy_err end
    if opts.callback then
        local original_callback = opts.callback
        opts.callback = function(response, err)
            -- Signal prompt completion
            utils.fire("MCPHubPromptEnd", {
                server = server_name,
                prompt = prompt_name,
                success = err == nil,
            })
            if opts.parse_response == true then
                response = prompt_utils.parse_prompt_response(response)
            end
            if original_callback then
                original_callback(response, err)
            end
        end
    end

    local request_options =
        vim.tbl_deep_extend("force", { timeout = self.mcp_request_timeout }, opts.request_options or {})
    -- Signal prompt start
    utils.fire("MCPHubPromptStart", {
        server = server_name,
        prompt = prompt_name,
    })
    local arguments = args or vim.empty_dict()
    if vim.islist(arguments) or vim.isarray(arguments) then
        if #arguments == 0 then
            arguments = vim.empty_dict()
        else
            log.error("Arguments should be a dictionary, but got a list.")
            return
        end
    end
    --make sure we have an object
    -- Check native servers first
    local is_native = native.is_native_server(server_name)
    if is_native then
        local server = is_native
        local result, err = server:get_prompt(prompt_name, args, opts)
        if opts.callback == nil then
            utils.fire("MCPHubPromptEnd", {
                server = server_name,
                prompt = prompt_name,
                success = err == nil,
            })
            return (opts.parse_response == true and prompt_utils.parse_prompt_response(result) or result), err
        end
        return
    end

    local response, err = self:api_request(
        "POST",
        "servers/prompts",
        vim.tbl_extend("force", {
            timeout = (request_options.timeout + 5000) or PROMPT_TIMEOUT,
            body = {
                server_name = server_name,
                prompt = prompt_name,
                arguments = arguments,
                request_options = request_options,
            },
        }, opts)
    )

    -- handle sync calls
    if opts.callback == nil then
        utils.fire("MCPHubPromptEnd", {
            server = server_name,
            prompt = prompt_name,
            success = err == nil,
        })
        return (opts.parse_response == true and prompt_utils.parse_prompt_response(response) or response), err
    end
end

--- Call a tool on a server
--- @param server_name string
--- @param tool_name string
--- @param args table
--- @param opts? {parse_response?: boolean, callback?: fun(res: MCPResponseOutput? ,err: string?), request_options?: MCPRequestOptions, timeout?: number } Optional callback(response: table|nil, error?: string) and timeout in ms (default 60s)
--- @return MCPResponseOutput?, string? If no callback is provided, returns response and error
function MCPHub:call_tool(server_name, tool_name, args, opts)
    opts = opts or {}
    local allowed, policy_err = check_project_server(server_name, opts)
    if not allowed then return nil, policy_err end
    if opts.callback then
        local original_callback = opts.callback
        opts.callback = function(response, err)
            -- Signal tool completion
            utils.fire("MCPHubToolEnd", {
                server = server_name,
                tool = tool_name,
                response = prompt_utils.parse_tool_response(response),
                success = err == nil,
            })
            if opts.parse_response == true then
                response = prompt_utils.parse_tool_response(response)
            end
            if original_callback then
                original_callback(response, err)
            end
        end
    end
    local request_options =
        vim.tbl_deep_extend("force", { timeout = self.mcp_request_timeout }, opts.request_options or {})
    -- Signal tool start
    utils.fire("MCPHubToolStart", {
        server = server_name,
        tool = tool_name,
    })
    local arguments = args or vim.empty_dict()
    if vim.islist(arguments) or vim.isarray(arguments) then
        if #arguments == 0 then
            arguments = vim.empty_dict()
        else
            log.error("Arguments should be a dictionary, but got a list.")
            return
        end
    end
    -- Check native servers first
    local is_native = native.is_native_server(server_name)
    if is_native then
        local server = is_native
        local result, err = server:call_tool(tool_name, args, opts)
        if opts.callback == nil then
            utils.fire("MCPHubToolEnd", {
                server = server_name,
                tool = tool_name,
                response = prompt_utils.parse_tool_response(result),
                success = err == nil,
            })
            return (opts.parse_response == true and prompt_utils.parse_tool_response(result) or result), err
        end
        return
    end

    local response, err = self:api_request(
        "POST",
        "servers/tools",
        vim.tbl_extend("force", {
            ---Make sure that actual curl request timeout is more than the MCP request timeout
            timeout = (request_options.timeout + 5000) or TOOL_TIMEOUT,
            body = {
                server_name = server_name,
                tool = tool_name,
                arguments = arguments,
                request_options = request_options,
            },
        }, opts)
    )

    -- handle sync calls
    if opts.callback == nil then
        utils.fire("MCPHubToolEnd", {
            server = server_name,
            tool = tool_name,
            response = prompt_utils.parse_tool_response(response),
            success = err == nil,
        })
        return (opts.parse_response == true and prompt_utils.parse_tool_response(response) or response), err
    end
end

--- Access a server resource
--- @param server_name string
--- @param uri string
--- @param opts? {parse_response?: boolean, callback?: fun(res: MCPResponseOutput? ,err: string?), request_options?: MCPRequestOptions, timeout?: number } Optional callback(response: table|nil, error?: string) and timeout in ms (default 60s)
--- @return MCPResponseOutput?, string? If no callback is provided, returns response and error
function MCPHub:access_resource(server_name, uri, opts)
    opts = opts or {}
    local allowed, policy_err = check_project_server(server_name, opts)
    if not allowed then return nil, policy_err end
    if opts.callback then
        local original_callback = opts.callback
        opts.callback = function(response, err)
            -- Signal resource completion
            utils.fire("MCPHubResourceEnd", {
                server = server_name,
                uri = uri,
                success = err == nil,
            })
            if opts.parse_response == true then
                response = prompt_utils.parse_resource_response(response)
            end
            if original_callback then
                original_callback(response, err)
            end
        end
    end

    local request_options =
        vim.tbl_deep_extend("force", { timeout = self.mcp_request_timeout }, opts.request_options or {})
    -- Signal resource start
    utils.fire("MCPHubResourceStart", {
        server = server_name,
        uri = uri,
    })

    -- Check native servers first
    local is_native = native.is_native_server(server_name)
    if is_native then
        local server = is_native
        local result, err = server:access_resource(uri, opts)
        if opts.callback == nil then
            utils.fire("MCPHubResourceEnd", {
                server = server_name,
                uri = uri,
                success = err == nil,
            })
            return (opts.parse_response == true and prompt_utils.parse_resource_response(result) or result), err
        end
        return
    end

    -- Otherwise proxy to MCP server
    local response, err = self:api_request(
        "POST",
        "servers/resources",
        vim.tbl_extend("force", {
            ---Make sure that actual curl request timeout is more than the MCP request timeout
            timeout = (request_options.timeout + 5000) or RESOURCE_TIMEOUT,
            body = {
                server_name = server_name,
                uri = uri,
                request_options = request_options,
            },
        }, opts)
    )
    -- handle sync calls
    if opts.callback == nil then
        utils.fire("MCPHubResourceEnd", {
            server = server_name,
            uri = uri,
            success = err == nil,
        })
        return (opts.parse_response == true and prompt_utils.parse_resource_response(response) or response), err
    end
end

--- API request helper
--- @param method string HTTP method
--- @param path string API path
--- @param opts? { body?: table, timeout?: number, skip_ready_check?: boolean, callback?: fun(response: table?, error: string?), query?: table }
--- @return table|nil, string|nil If no callback is provided, returns response and error
function MCPHub:api_request(method, path, opts)
    opts = opts or {}
    if method == "POST" and opts.body and opts.body.server_name
        and (path == "servers/start" or path == "servers/tools" or path == "servers/resources" or path == "servers/prompts") then
        local allowed, policy_err = check_project_server(opts.body.server_name, opts)
        if not allowed then return nil, policy_err end
    end
    local callback = opts.callback
    -- the url of the mcp-hub server if it is hosted somewhere (e.g. https://mydomain.com)
    local base_url = self.server_url or string.format("http://localhost:%d", self.port)
    --remove any trailing slashes
    base_url = base_url:gsub("/+$", "")

    -- Build URL with query parameters if any
    local url = string.format("%s/api/%s", base_url, path)
    if opts.query then
        local params = {}
        for k, v in pairs(opts.query) do
            table.insert(params, k .. "=" .. v)
        end
        url = url .. "?" .. table.concat(params, "&")
    end

    local raw = {}
    vim.list_extend(raw, {
        "--connect-timeout",
        tostring(vim.fn.floor(CONNECT_TIMEOUT / 1000)),
    })
    if opts.timeout then
        local timeout_seconds = tostring(vim.fn.floor((opts.timeout or TOOL_TIMEOUT) / 1000))
        vim.list_extend(raw, {
            "--max-time",
            timeout_seconds,
        })
    end

    -- Prepare request options
    local request_opts = {
        url = url,
        method = method,
        --INFO: generating custom headers file path to avoid getting .header file not found when simulataneous requests are sent
        dump = utils.gen_dump_path(),
        headers = {
            ["Content-Type"] = "application/json",
            ["Accept"] = "application/json",
        },
        raw = raw,
        on_error = vim.schedule_wrap(function(err)
            log.debug(string.format("Error while making request to %s: %s", path, vim.inspect(err)))
            local error = handlers.ResponseHandlers.process_error(err)
            if not self:is_ready() and path == "health" then
                if callback then
                    callback(nil, tostring(error))
                end
            else
                if callback then
                    callback(nil, tostring(error))
                end
                State:add_error(error)
            end
        end),
    }
    if opts.body then
        request_opts.body = vim.fn.json_encode(opts.body)
    end

    -- Only skip ready check for health check
    if not opts.skip_ready_check and not self.ready and path ~= "health" then
        local err = Error("SERVER", Error.Types.SERVER.INVALID_STATE, "MCP Hub not ready")
        State:add_error(err)
        if callback then
            callback(nil, tostring(err))
            return
        else
            return nil, tostring(err)
        end
    end

    -- Process response
    local function process_response(response)
        local curl_error = handlers.ResponseHandlers.handle_curl_error(response, request_opts)
        if curl_error then
            State:add_error(curl_error)
            if callback then
                callback(nil, tostring(curl_error))
                return
            else
                return nil, tostring(curl_error)
            end
        end

        local http_error = handlers.ResponseHandlers.handle_http_error(response, request_opts)
        if http_error then
            State:add_error(http_error)
            if callback then
                callback(nil, tostring(http_error))
                return
            else
                return nil, tostring(http_error)
            end
        end

        local result, parse_error = handlers.ResponseHandlers.parse_json(response.body, request_opts)
        if parse_error then
            State:add_error(parse_error)
            if callback then
                callback(nil, tostring(parse_error))
                return
            else
                return nil, tostring(parse_error)
            end
        end

        if callback then
            callback(result)
        else
            return result
        end
    end

    if callback then
        -- Async mode
        curl.request(vim.tbl_extend("force", request_opts, {
            callback = vim.schedule_wrap(function(response)
                process_response(response)
            end),
        }))
    else
        -- Sync mode
        return process_response(curl.request(request_opts))
    end
end

--- Refresh cache of config files
---@param paths string[]|nil
function MCPHub:reload_config(paths)
    local success, err = config_manager.refresh_config(paths)
    if not success then
        self:handle_hub_stopped("Failed to reload MCP servers configuration: " .. (err or ""))
        return
    end
    -- Native connection state is process runtime state. Exact-workspace
    -- administrator policy is enforced by completion/load/call boundaries.
    self:refresh_native_servers()
end

function MCPHub:refresh_native_servers()
    self:fire_servers_updated()
end

function MCPHub:fire_servers_updated()
    -- Update global state
    self:_update_global_state()

    -- Triggers UI update
    State:notify_subscribers({
        server_state = true,
    }, "server")

    -- Useful for lualine and other extensions
    utils.fire("MCPHubServersUpdated", {
        active_servers = #self:get_servers(),
    })
    State:emit("servers_updated", {
        hub = self,
    })
end

function MCPHub:update_servers(response, callback)
    callback = callback or function() end
    local servers = response and response.servers or nil
    local workspaces = response and response.workspaces or nil
    local function update_state(_servers, workspaces)
        if _servers then
            State.server_state.servers = _servers or {}
        end
        if workspaces then
            State.server_state.workspaces = workspaces or {}
        end
        self:fire_servers_updated()
    end
    if servers or workspaces then
        update_state(servers, workspaces)
    else
        self:get_health({
            callback = function(response, err)
                if err then
                    local health_err = Error("SERVER", Error.Types.SERVER.HEALTH_CHECK, "Health check failed", {
                        error = err,
                    })
                    State:add_error(health_err)
                    callback(false)
                else
                    update_state(response.servers or {}, response.workspaces or {})
                    callback(true)
                end
            end,
        })
    end
end

function MCPHub:handle_capability_updates(data)
    local type = data.type
    local server = data.server
    local map = {
        [constants.SubscriptionTypes.TOOL_LIST_CHANGED] = { "tools" },
        [constants.SubscriptionTypes.RESOURCE_LIST_CHANGED] = { "resources", "resourceTemplates" },
        [constants.SubscriptionTypes.PROMPT_LIST_CHANGED] = { "prompts" },
    }
    local fields_to_update = map[type]
    if not fields_to_update then
        log.warn("Unknown capability update type: " .. type)
        return
    end
    if not server then
        return
    end
    for _, s in ipairs(State.server_state.servers) do
        if s.name == server then
            local emit_data = {
                server = server,
                hub = self,
            }
            for _, field in ipairs(fields_to_update) do
                s.capabilities[field] = data[field] or {}
                emit_data[field] = s.capabilities[field]
            end
            State:emit(type, emit_data)
            break
        end
    end
    -- Notify subscribers of state change
    State:notify_subscribers({
        server_state = true,
    }, "server")
end

--- Update server configuration in the MCP config file
---@param server_name string Name of the server to update
---@param updates table|nil Key-value pairs to update in the server config or nil to remove
---@param opts? { merge:boolean?, config_source: string? } Optional callback(success: boolean)
---@return boolean, string|nil Returns success status and error message if any
function MCPHub:update_server_config(server_name, updates, opts)
    return config_manager.update_server_config(server_name, updates, opts)
end

--- Remove server configuration
---@param server_name string Server ID to remove
---@return boolean, string|nil Returns success status and error message if any
function MCPHub:remove_server_config(server_name)
    -- Use update_server_config with nil updates to remove
    return self:update_server_config(server_name, nil)
end

function MCPHub:stop()
    self.is_shutting_down = true
    -- Stop SSE connection
    self:stop_sse()
    self:_clean_up()
    self.is_shutting_down = false
end

function MCPHub:is_ready()
    return self.ready
end

--- Connect to SSE events endpoint
function MCPHub:connect_sse()
    if self.sse_job then
        return
    end
    local buffer = ""
    local base_url = self.server_url or string.format("http://localhost:%d", self.port)
    base_url = base_url:gsub("/+$", "")

    -- Create SSE connection
    ---@diagnostic disable-next-line: missing-fields
    local sse_job = Job:new({
        command = "curl",
        args = {
            "--no-buffer",
            "--tcp-nodelay",
            "--retry",
            "5",
            "--retry-delay",
            "1",
            "--retry-connrefused",
            "--keepalive-time",
            "60",
            base_url .. "/api/events",
        },
        on_stdout = vim.schedule_wrap(function(_, data)
            if data ~= nil then
                buffer = buffer .. data .. "\n"

                while true do
                    local event_end = buffer:find("\n\n")
                    if not event_end then
                        break
                    end

                    local event_str = buffer:sub(1, event_end - 1)
                    buffer = buffer:sub(event_end + 2)

                    local event = event_str:match("^event: (.-)\n")
                    local data_line = event_str:match("\ndata: ([^\r\n]+)")

                    if event and data_line then
                        local success, decoded = utils.json_decode(data_line)
                        if success then
                            log.trace(string.format("SSE event: %s", event))
                            handlers.SSEHandlers.handle_sse_event(event, decoded, self)
                        else
                            log.warn(string.format("Failed to decode SSE data: %s", data_line))
                        end
                    else
                        log.warn(string.format("Malformed SSE event: %s", event_str))
                    end
                end
            end
        end),
        on_stderr = vim.schedule_wrap(function(_, data)
            log.debug("SSE STDERR: " .. tostring(data))
        end),
        on_exit = vim.schedule_wrap(function(_, code)
            log.debug("SSE JOB exited with " .. tostring(code))
            self.sse_job = nil
            self:handle_hub_stopped("SSE connection failed with code " .. tostring(code), code)
        end),
    })

    -- Store SSE job for cleanup
    self.sse_job = sse_job
    sse_job:start()
end

--- Stop SSE connection
function MCPHub:stop_sse()
    if self.sse_job then
        self.sse_job:shutdown(0)
        self.sse_job = nil
    end
end

function MCPHub:refresh(callback)
    callback = callback or function() end
    self:update_servers(nil, callback)
end

function MCPHub:hard_refresh(callback)
    callback = callback or function() end
    if not self:ensure_ready() then
        return
    end
    self:api_request("GET", "refresh", {
        callback = function(response, err)
            if err then
                local health_err = Error("SERVER", Error.Types.SERVER.HEALTH_CHECK, "Hard Refresh failed : " .. err, {
                    error = err,
                })
                State:add_error(health_err)
                callback(false)
            else
                self:update_servers(response)
                callback(true)
            end
        end,
    })
end

function MCPHub:handle_hub_restarting()
    --for non owner client
    self.is_restarting = true
    State:update({
        errors = {
            items = {},
        },
        server_output = {
            entries = {},
        },
    }, "server")
end

function MCPHub:handle_hub_stopping()
    if self.is_restarting then
        vim.defer_fn(function()
            self:start()
        end, 1000)
    end
end

--- Handles already running mcp-hub on same port with different config files
---@param context table Context containing port and config details
function MCPHub:handle_same_port_different_config(context)
    self:api_request("POST", "hard-restart", {
        callback = function(_, err)
            if err then
                local restart_err = Error("SERVER", Error.Types.SERVER.RESTART, "Hard restart failed", {
                    error = err,
                })
                State:add_error(restart_err)
                vim.notify(
                    "Failed to restart MCP Hub while trying to stop mcp-hub running on port " .. context.port,
                    vim.log.levels.ERROR
                )
                return
            end
            self:_start_server_with_context(context)
        end,
        skip_ready_check = true,
    })
end

--- Restart the MCP Hub server
--- @param callback function|nil Optional callback to execute after restart
--- @param reason string|nil Optional reason for the restart
function MCPHub:restart(callback, reason)
    if not self:ensure_ready() then
        return self:start()
    end
    if self.is_restarting then
        vim.notify("MCP Hub is already restarting.", vim.log.levels.WARN)
        return
    end
    self.is_restarting = true
    self:api_request("POST", "hard-restart", {
        callback = function(_, err)
            if err then
                local restart_err = Error("SERVER", Error.Types.SERVER.RESTART, "Hard restart failed", {
                    error = err,
                })
                State:add_error(restart_err)
                if callback then
                    callback(false)
                end
                return
            end
            if callback then
                callback(true)
            end
        end,
    })
end

function MCPHub:ensure_ready()
    if not self:is_ready() then
        log.warn("Hub is not ready.")
        return false
    end
    return true
end

--- Get servers with their tools filtered based on server config
--- @param server MCPServer The server object to filter
---@return table[] Array of connected servers with disabled tools filtered out
local function filter_server_capabilities(server)
    local config = config_manager.get_server_config(server) or {}
    local filtered_server = vim.deepcopy(server)
    if filtered_server.capabilities then
        filtered_server.capabilities = config_manager.filter_capabilities(filtered_server.capabilities, config)
    end
    return filtered_server
end

---resolve any functions in the native servers
---@param native_server NativeServer
---@return table
local function resolve_native_server(native_server)
    local server = vim.deepcopy(native_server)
    local possible_func_fields = {
        tools = { "description", "inputSchema" },
        resources = { "description" },
        resourceTemplates = { "description" },
        prompts = { "description" },
    }
    --first resolve the server desc itself
    server.description = prompt_utils.get_description(server)

    for cap_type, fields in pairs(possible_func_fields) do
        for _, capability in ipairs(server.capabilities[cap_type] or {}) do
            --remove handler as it is not in std protocol
            capability.handler = nil
            capability.display = nil
            capability.ui = nil
            capability.interactive = nil
            for _, field in ipairs(fields) do
                if capability[field] then
                    if field == "description" then --resolves to string
                        capability[field] = prompt_utils.get_description(capability)
                    elseif field == "inputSchema" then --resolves to inputSchema table
                        capability[field] = prompt_utils.get_inputSchema(capability)
                    end
                end
            end
        end
    end
    return server
end

---@param include_disabled? boolean
---@return MCPServer[]
function MCPHub:get_servers(include_disabled)
    include_disabled = include_disabled == true
    if not self:is_ready() then
        return {}
    end
    local filtered_servers = {}

    -- Add regular MCP servers
    for _, server in ipairs(State.server_state.servers or {}) do
        if server.status == "connected" or include_disabled then
            local filtered_server = filter_server_capabilities(server)
            table.insert(filtered_servers, filtered_server)
        end
    end

    -- Add native servers
    for _, server in ipairs(State.server_state.native_servers or {}) do
        if server.status == "connected" or include_disabled then
            local filtered_server = filter_server_capabilities(server)
            --INFO: this is for cases where chat plugins expect std MCP definations to remove mcphub specific enhancements
            local resolved_server = resolve_native_server(filtered_server)
            table.insert(filtered_servers, resolved_server)
        end
    end

    return filtered_servers
end

---@return EnhancedMCPPrompt[]
function MCPHub:get_prompts()
    local active_servers = self:get_servers()
    local prompts = {}
    for _, server in ipairs(active_servers) do
        if server.capabilities and server.capabilities.prompts then
            for _, prompt in ipairs(server.capabilities.prompts) do
                table.insert(
                    prompts,
                    vim.tbl_extend("force", prompt, {
                        server_name = server.name,
                    })
                )
            end
        end
    end
    return prompts
end

---@return EnhancedMCPResource[]
function MCPHub:get_resources()
    local active_servers = self:get_servers()
    local resources = {}
    for _, server in ipairs(active_servers) do
        if server.capabilities and server.capabilities.resources then
            for _, resource in ipairs(server.capabilities.resources) do
                table.insert(
                    resources,
                    vim.tbl_extend("force", resource, {
                        server_name = server.name,
                    })
                )
            end
        end
    end
    return resources
end

---@return EnhancedMCPResourceTemplate[]
function MCPHub:get_resource_templates()
    local active_servers = self:get_servers()
    local resource_templates = {}
    for _, server in ipairs(active_servers) do
        if server.capabilities and server.capabilities.resourceTemplates then
            for _, resource_template in ipairs(server.capabilities.resourceTemplates) do
                table.insert(
                    resource_templates,
                    vim.tbl_extend("force", resource_template, {
                        server_name = server.name,
                    })
                )
            end
        end
    end
    return resource_templates
end

---@return EnhancedMCPTool[]
function MCPHub:get_tools()
    local active_servers = self:get_servers()
    local tools = {}
    for _, server in ipairs(active_servers) do
        if server.capabilities and server.capabilities.tools then
            for _, tool in ipairs(server.capabilities.tools) do
                table.insert(
                    tools,
                    vim.tbl_extend("force", tool, {
                        server_name = server.name,
                    })
                )
            end
        end
    end
    return tools
end

--- Convert server to text format
--- @param server MCPServer
--- @return string
function MCPHub:convert_server_to_text(server)
    local filtered_server = filter_server_capabilities(server)
    return prompt_utils.server_to_text(filtered_server)
end

--- Get active servers prompt
--- @param add_example? boolean Whether to add example to the prompt
--- @param include_disabled? boolean Whether to include disabled servers
--- @return string
function MCPHub:get_active_servers_prompt(add_example, include_disabled)
    include_disabled = include_disabled == true
    add_example = add_example ~= false
    if not self:is_ready() then
        return ""
    end
    return prompt_utils.get_active_servers_prompt(self:get_servers(include_disabled), add_example, include_disabled)
end

--- Get all MCP system prompts
---@param opts? {use_mcp_tool_example?: string, add_example?: boolean, include_disabled?: boolean, access_mcp_resource_example?: string}
---@return {active_servers: string|nil, use_mcp_tool: string|nil, access_mcp_resource: string|nil}
function MCPHub:generate_prompts(opts)
    if not self:ensure_ready() then
        return {}
    end
    opts = opts or {}
    return {
        active_servers = self:get_active_servers_prompt(opts.add_example, opts.include_disabled),
        use_mcp_tool = prompt_utils.get_use_mcp_tool_prompt(opts.use_mcp_tool_example),
        access_mcp_resource = prompt_utils.get_access_mcp_resource_prompt(opts.access_mcp_resource_example),
    }
end

--- Update global variables for lualine integration
function MCPHub:_update_global_state()
    vim.g.mcphub_status = State.server_state.state
    vim.g.mcphub_servers_count = #self:get_servers()
end

--- Setup global variable tracking for tool/resource execution
function MCPHub:_setup_global_state_tracking()
    local group = vim.api.nvim_create_augroup("mcphub_global_state", { clear = true })

    -- Track tool/resource/prompt execution
    vim.api.nvim_create_autocmd("User", {
        group = group,
        pattern = { "MCPHubToolStart", "MCPHubResourceStart", "MCPHubPromptStart" },
        callback = function()
            vim.g.mcphub_executing = true
        end,
    })

    vim.api.nvim_create_autocmd("User", {
        group = group,
        pattern = { "MCPHubToolEnd", "MCPHubResourceEnd", "MCPHubPromptEnd" },
        callback = function()
            vim.g.mcphub_executing = false
        end,
    })
end

return MCPHub
