---[[
--- UI Core for MCPHub
--- Handles window/buffer management and view system
---]]
local State = require("maxa.mcphub.state")
local hl = require("maxa.mcphub.utils.highlights")
local utils = require("maxa.mcphub.utils")

---@class MCPHub.UI
---@field window number Window handle
---@field buffer number Buffer handle
---@field current_view MCPHub.UI.ViewName Current view name
---@field views table Table of view instances
---@field is_shown boolean Whether the UI is currently visible
---@field cursor_states table Store cursor positions by view name
---@field context table Context from which the UI was opened
---@field opts MCPHub.UIConfig Configuration options for UI
---@field _unsubscribe_state? function Removes this instance's State subscription
local UI = {}
UI.__index = UI

---@enum MCPHub.UI.ViewName
local ViewName = {
    MAIN = "main",
    LOGS = "logs",
    HELP = "help",
}

-- Default window settings
---@class MCPHub.UIConfig
local defaults = {
    window = {
        width = 0.8, -- 0-1 (ratio); "50%" (percentage); 50 (raw number)
        height = 0.8, -- 0-1 (ratio); "50%" (percentage); 50 (raw number)
        align = "center", -- "center", "top-left", "top-right", "bottom-left", "bottom-right", "top", "bottom", "left", "right"
        border = nil, -- When nil, uses vim.o.winborder. Can be set to "none", "single", "double", "rounded", "solid", "shadow" to override
        relative = "editor",
        zindex = 50,
    },
    ---@type table?
    wo = { -- window-scoped options (vim.wo)
    },
}

-- Parse size value into actual numbers
---@param value any Size value (number, float, or percentage string)
---@param total number Total available size
---@return number Calculated size
local function parse_size(value, total)
    if type(value) == "number" then
        if value <= 1 then -- Ratio
            return math.floor(total * value)
        end
        return math.floor(value) -- Raw number
    elseif type(value) == "string" then
        -- Parse percentage (e.g., "80%")
        local percent = tonumber(value:match("(%d+)%%"))
        if percent then
            return math.floor((total * percent) / 100)
        end
    end
    return math.floor(total * 0.8) -- Default fallback
end

--- Create a new UI instance
---@param opts? MCPHub.UIConfig Configuration options for UI
---@return MCPHub.UI
function UI:new(opts)
    local instance = setmetatable({
        window = nil, -- Window handle
        buffer = nil, -- Buffer handle
        current_view = nil, -- Current view name
        views = {}, -- View instances
        is_shown = false, -- Whether the UI is currently visible
        cursor_states = {}, -- Store cursor positions by view name
        context = {}, -- Context from which the UI was opened
    }, self)
    instance.opts = vim.tbl_deep_extend("force", defaults, opts or {})

    local ok, err = xpcall(function()
        instance:init_views()

        instance._state_callback = function(_, changes)
            if instance.window and vim.api.nvim_win_is_valid(instance.window) then
                local should_update = false
                local keys = {
                    "server_output",
                    "setup_state",
                    "server_state",
                    "config_files_cache",
                    "logs",
                    "errors",
                }
                for k, _ in pairs(changes) do
                    if vim.tbl_contains(keys, k) then
                        should_update = k ~= "logs" or not State:is_connected() or instance.current_view == "logs"
                        break
                    end
                end
                if should_update then
                    instance:render()
                end
            end
        end
        instance._state_subscription_types = { "ui", "server", "logs", "setup", "errors" }
        instance._unsubscribe_state = State:subscribe(instance._state_callback, instance._state_subscription_types)

        local group = vim.api.nvim_create_augroup("mcphub_ui", { clear = true })
        vim.api.nvim_create_autocmd("VimLeavePre", {
            group = group,
            callback = function() instance:dispose() end,
        })
        vim.api.nvim_create_autocmd("VimResized", {
            group = group,
            callback = function()
                if instance.window and vim.api.nvim_win_is_valid(instance.window) then
                    instance:resize_window()
                end
            end,
        })
        vim.api.nvim_create_autocmd("User", {
            group = group,
            pattern = "MaxaProjectSettingsChanged",
            callback = function(args)
                if instance.is_shown and args.data and args.data.project_root == instance.project_root then instance:render() end
            end,
        })
        vim.api.nvim_create_autocmd("WinClosed", {
            group = group,
            callback = function(args)
                if instance.window and tonumber(args.match) == instance.window then
                    instance:cleanup()
                end
            end,
        })
    end, debug.traceback)
    if not ok then
        instance:dispose()
        error(err)
    end
    return instance
end

--- Initialize views
---@private
function UI:init_views()
    local MainView = require("maxa.mcphub.ui.views.main")

    -- Create view instances
    self.views = {
        main = MainView:new(self),
        logs = require("maxa.mcphub.ui.views.logs"):new(self),
        help = require("maxa.mcphub.ui.views.help"):new(self),
        project = require("maxa.mcphub.ui.views.project"):new(self),
        defaults = require("maxa.mcphub.ui.views.defaults"):new(self),
    }

    -- Set initial view
    self.current_view = "project"
end

--- Create a new buffer for the UI
---@private
function UI:create_buffer()
    self.buffer = vim.api.nvim_create_buf(false, true)

    -- Set buffer options
    vim.api.nvim_buf_set_option(self.buffer, "modifiable", false)
    vim.api.nvim_buf_set_option(self.buffer, "bufhidden", "wipe")
    vim.api.nvim_buf_set_option(self.buffer, "filetype", "mcphub")
    vim.api.nvim_buf_set_option(self.buffer, "wrap", true)

    -- Set buffer mappings
    self:setup_keymaps()

    return self.buffer
end

--- Calculate window dimensions and position
---@private
function UI:calculate_window_dimensions()
    local min_width = 50
    local min_height = 10
    local win_opts = self.opts.window

    -- Calculate dimensions
    local width = parse_size(win_opts.width, vim.o.columns)
    width = math.max(min_width, width)

    local height = parse_size(win_opts.height, vim.o.lines)
    height = math.max(min_height, height)

    -- Calculate position based on alignment
    local row, col
    local align = win_opts.align or "center"

    if align == "center" then
        row = math.floor((vim.o.lines - height) / 2)
        col = math.floor((vim.o.columns - width) / 2)
    elseif align == "top-left" then
        row = 1
        col = 1
    elseif align == "top-right" then
        row = 1
        col = vim.o.columns - width
    elseif align == "bottom-left" then
        row = vim.o.lines - height
        col = 1
    elseif align == "bottom-right" then
        row = vim.o.lines - height
        col = vim.o.columns - width
    elseif align == "top" then
        row = 1
        col = math.floor((vim.o.columns - width) / 2)
    elseif align == "bottom" then
        row = vim.o.lines - height
        col = math.floor((vim.o.columns - width) / 2)
    elseif align == "left" then
        row = math.floor((vim.o.lines - height) / 2)
        col = 1
    elseif align == "right" then
        row = math.floor((vim.o.lines - height) / 2)
        col = vim.o.columns - width
    else
        -- Default to center for unknown alignment
        row = math.floor((vim.o.lines - height) / 2)
        col = math.floor((vim.o.columns - width) / 2)
    end

    return {
        width = width,
        height = height,
        row = row,
        col = col,
    }
end

--- Resize the window when editor is resized
---@private
function UI:resize_window()
    if not self.window or not vim.api.nvim_win_is_valid(self.window) then
        return
    end
    vim.api.nvim_win_set_config(self.window, self:get_window_config())
    -- Force a re-render of the current view
    self:render()
end

function UI:get_window_config()
    local dims = self:calculate_window_dimensions()
    local win_opts = self.opts.window

    return {
        relative = win_opts.relative,
        width = dims.width,
        height = dims.height,
        row = dims.row,
        col = dims.col,
        style = "minimal",
        border = win_opts.border,
        zindex = win_opts.zindex,
    }
end

--- Create a floating window
---@private
---@return number Window handle
function UI:create_window()
    if not self.buffer or not vim.api.nvim_buf_is_valid(self.buffer) then
        self:create_buffer()
    end

    -- Create floating window
    self.window = vim.api.nvim_open_win(self.buffer, true, self:get_window_config())

    for k, v in pairs(self.opts.wo or {}) do
        vim.api.nvim_set_option_value(k, v, { scope = "local", win = self.window })
    end

    return self.window
end

--- Set up view-specific keymaps
function UI:setup_keymaps()
    local function map(key, action, desc)
        vim.keymap.set("n", key, action, {
            buffer = self.buffer,
            desc = desc,
            nowait = true,
        })
    end

    -- Global navigation
    map("D", function()
        self:switch_view("defaults")
    end, "Project service defaults")

    map("P", function()
        self:switch_view("project")
    end, "Project settings")

    map("H", function()
        self:switch_view("main")
    end, "Switch to Home view")

    map("L", function()
        self:switch_view("logs")
    end, "Switch to Logs view")

    map("?", function()
        self:switch_view("help")
    end, "Switch to Help view")

    -- Close window
    map("q", function()
        self:cleanup()
    end, "Close")

    map("r", function()
        self:hard_refresh()
    end, "Refresh")
    map("R", function()
        self:restart()
    end, "Restart")
end

function UI:refresh()
    if State.hub_instance then
        vim.notify("Refreshing")
        if State.hub_instance:refresh() then
            vim.notify("Refreshed")
        else
            vim.notify("Failed to refresh")
        end
    else
        vim.notify("No hub instance available")
    end
end

function UI:restart()
    if State.hub_instance then
        State.hub_instance:restart(function(success)
            if success then
                vim.notify("Restarting...")
            else
                vim.notify("Failed to restart")
            end
        end)
        vim.schedule(function()
            self:switch_view("main")
        end)
    else
        vim.notify("No hub instance available")
    end
end

function UI:hard_refresh()
    if State.hub_instance then
        vim.notify("Updating all server capabilities")
        State.hub_instance:hard_refresh(function(success)
            if success then
                vim.notify("Refreshed")
            else
                vim.notify("Failed to refresh")
            end
        end)
    else
        vim.notify("No hub instance available")
    end
end

--- Clean up resources
function UI:cleanup()
    if self.buffer and vim.api.nvim_buf_is_valid(self.buffer) then
        vim.api.nvim_buf_delete(self.buffer, { force = true })
    end

    if self.window and vim.api.nvim_win_is_valid(self.window) then
        vim.api.nvim_win_close(self.window, true)
    end
    self.buffer = nil
    self.window = nil
    self.is_shown = false
end

--- Release subscriptions and autocmds owned by this UI instance.
function UI:dispose()
    self:cleanup()
    if self._unsubscribe_state then
        self._unsubscribe_state()
        self._unsubscribe_state = nil
    end
    self._state_callback = nil
    self._state_subscription_types = nil
    pcall(vim.api.nvim_del_augroup_by_name, "mcphub_ui")
end

--- Toggle UI visibility
--- @param args? table
function UI:toggle(args)
    if self.window and vim.api.nvim_win_is_valid(self.window) then
        self:cleanup()
    else
        self:show(args)
    end
end

--- Switch to a different view
---@param view_name MCPHub.UI.ViewName Name of view to switch to
function UI:switch_view(view_name)
    -- Leave current view if any
    if self.current_view and self.views[self.current_view] and self.is_shown then
        self.views[self.current_view]:before_leave()
        self.views[self.current_view]:after_leave()
    end

    -- Switch view
    self.current_view = view_name

    -- Restore global mappings cleared by the previous view's local overrides.
    if self.buffer and vim.api.nvim_buf_is_valid(self.buffer) then
        self:setup_keymaps()
    end

    -- Enter new view
    if self.views[view_name] then
        self.views[view_name]:before_enter()
        self.views[view_name]:draw()
        self.views[view_name]:after_enter()
    end
end

--- Show the UI window
--- @param args? table
function UI:show(args)
    local bufnr = vim.api.nvim_get_current_buf()
    self.project_root = require("maxa.project.settings").context_root(bufnr)
    local runtime = package.loaded["maxa"]
    self.invoking_chat = runtime and runtime.buf_get_chat and runtime.buf_get_chat(bufnr) or nil
    self.context = utils.get_buf_info(bufnr, args)
    -- Create/show window if needed
    if not self.window or not vim.api.nvim_win_is_valid(self.window) then
        self:create_window()
    end
    -- Focus window
    vim.api.nvim_set_current_win(self.window)

    -- Draw current view
    self:render()
    self.is_shown = true
end

--- Render current view
---@private
function UI:render()
    self:switch_view(self.current_view)
end

return UI
