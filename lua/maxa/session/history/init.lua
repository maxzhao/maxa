---@class MaxaAI.History
---@field opts MaxaAI.History.Opts
---@field storage MaxaAI.History.Storage
---@field title_generator MaxaAI.History.TitleGenerator
---@field ui MaxaAI.History.UI
---@field should_load_last_chat boolean
---@field new fun(opts: MaxaAI.History.Opts): MaxaAI.History
local History = {}

local function emit_title_changed(chat, title, previous_title)
    if not chat or type(title) ~= "string" or title == "" or title == previous_title then
        return
    end
    chat.title = title
    local opts = type(chat.opts) == "table" and chat.opts or {}
    -- User autocommand data is converted through the Nvim API boundary and
    -- cannot contain full Maxa AI chat objects because they may embed
    -- userdata. Emit stable identifiers only; consumers can resolve the chat
    -- from bufnr/save_id when they need runtime-only state.
    local data = {
        bufnr = chat.bufnr,
        save_id = opts.save_id or chat.save_id,
        cwd = opts.cwd or chat.cwd,
        title = title,
        previous_title = previous_title,
    }
    vim.schedule(function()
        vim.api.nvim_exec_autocmds("User", {
            pattern = "MaxaAIChatTitleChanged",
            data = data,
        })
    end)
end
local log = require("maxa.session.history.log")
local pickers = require("maxa.session.history.pickers")
local utils = require("maxa.session.history.utils")

---Monkey patch to save some extra fields in the Chat instance
---@class MaxaAI.History.ChatArgs : MaxaAI.ChatArgs
---@field save_id string?
---@field title string?
---@field title_refresh_count integer? Number of times the title has been refreshed
---@field cwd string? Current working directory when chat was saved

---@class MaxaAI.History.Chat : MaxaAI.Chat
---@field opts MaxaAI.History.ChatArgs

---@type MaxaAI.History|nil
local history_instance

---@type MaxaAI.History.Opts
local default_opts = {
    ---A name for the chat buffer that tells that this is a auto saving chat
    default_buf_title = "[Maxa AI] " .. " ",

    ---Keymap to open history from chat buffer (default: gh)
    keymap = "gh",
    ---Description for the history keymap (for which-key integration)
    keymap_description = "Browse saved chats",
    ---Keymap to save the current chat manually (when auto_save is disabled)
    save_chat_keymap = "sc",
    ---Description for the save chat keymap (for which-key integration)
    save_chat_keymap_description = "Save current chat",
    ---Save all chats by default (disable to save only manually using 'sc')
    auto_save = true,
    ---Number of days after which chats are automatically deleted (0 to disable)
    expiration_days = 0,
    ---Valid Picker interface ("telescope", "snacks", "fzf-lua", or "default")
    ---@type MaxaAI.History.Pickers
    picker = pickers.history,
    picker_keymaps = {
        rename = {
            n = "r",
            i = "<M-r>",
        },
        delete = {
            n = "d",
            i = "<M-d>",
        },
        duplicate = {
            n = "<C-y>",
            i = "<C-y>",
        },
        stats = {
            n = "s",
            i = "<M-s>",
        },
        copy_to_project = {
            n = "Y",
            i = "<M-y>",
        },
        move_to_project = {
            n = "M",
            i = "<M-m>",
        },
    },
    ---Automatically generate titles for new chats
    auto_generate_title = true,
    title_generation_opts = {
        ---Adapter for generating titles (defaults to current chat adapter)
        adapter = nil,
        ---Model for generating titles (defaults to current chat model)
        model = nil,
        ---Number of user prompts after which to refresh the title (0 to disable)
        refresh_every_n_prompts = 0,
        ---Maximum number of times to refresh the title (default: 3)
        max_refreshes = 3,
        format_title = nil,
    },
    ---On exiting and entering neovim, loads the last chat on opening chat
    continue_last_chat = false,
    ---When chat is cleared with `gx` delete the chat from history
    delete_on_clearing_chat = false,
    ---Directory path to save the chats
    dir_to_save = vim.fs.joinpath(vim.fn.stdpath("data"), "maxa-ai", "history"),
    ---Enable detailed logging for history extension
    enable_logging = false,
    ---Filter function for browsing chats (defaults to show all chats)
    chat_filter = nil,
}

---@class MaxaAI.History
---@param opts MaxaAI.History.Opts
---@return MaxaAI.History
function History.new(opts)
    local history = setmetatable({}, {
        __index = History,
    })
    history.opts = opts
    history.storage = require("maxa.session.history.storage").new(opts)
    history.title_generator = require("maxa.session.history.title_generator").new(opts)
    history.ui = require("maxa.session.history.ui").new(opts, history.storage, history.title_generator)
    history.should_load_last_chat = opts.continue_last_chat

    -- Setup commands
    history:_create_commands()
    history:_setup_autocommands()
    history:_setup_keymaps()
    return history --[[@as MaxaAI.History]]
end

function History:_create_commands()
    vim.api.nvim_create_user_command("MaxaHistory", function()
        self.ui:open_saved_chats(self.opts.chat_filter)
    end, {
        desc = "Open saved chats",
    })

end

function History:_setup_autocommands()
    local group = vim.api.nvim_create_augroup("MaxaHistory", { clear = true })
    -- util.fire("ChatCreated", { bufnr = self.bufnr, from_prompt_library = self.from_prompt_library, id = self.id })
    vim.api.nvim_create_autocmd("User", {
        pattern = "MaxaAIChatCreated",
        group = group,
        callback = vim.schedule_wrap(function(opts)
            -- data = {
            --   bufnr = 5,
            --   from_prompt_library = false,
            --   id = 7463137
            -- },
            log:trace("Chat created event received")
            local chat_module = require("maxa.interactions.chat")
            local bufnr = opts.data.bufnr
            local chat = chat_module.buf_get_chat(bufnr) --[[@as MaxaAI.History.Chat]]
            if not chat then
                return log:trace("Chat created event skipped: chat no longer exists for bufnr %s", tostring(bufnr))
            end

            if self.should_load_last_chat then
                log:trace("Attempting to load last chat")
                self.should_load_last_chat = false
                local last_saved_chat = self.storage:get_last_chat(function(entry)
                    return require("maxa.session.agent_identity").history(entry).kind == "main"
                        and (not self.opts.chat_filter or self.opts.chat_filter(entry))
                end)
                if last_saved_chat then
                    log:trace("Restoring last saved chat")
                    chat:close()
                    self.ui:create_chat(last_saved_chat)
                    return
                end
            end
            -- Set initial buffer title
            if chat.opts.title then
                log:trace("Setting existing chat title: %s", chat.opts.title)
                self.ui:update_chat_title(chat) -- Use new method
            else
                --set title to tell that this is a auto saving chat
                self.ui:update_chat_title(chat) -- Use new method
            end

            --Check if custom save_id exists, else generate
            if not chat.opts.save_id then
                chat.opts.save_id = utils.generate_save_id({ history_dir = self.storage and self.storage.base_path })
                log:trace("Generated new save_id: %s", chat.opts.save_id)
            end

            -- self:_subscribe_to_chat(chat)
        end),
    })
    vim.api.nvim_create_autocmd("User", {
        pattern = "MaxaAI*Finished",
        group = group,
        callback = vim.schedule_wrap(function(opts)
            if not self.opts.auto_save then
                return
            end
            if opts.match == "MaxaAIRequestFinished" or opts.match == "MaxaAIToolsFinished" then
                log:trace("Chat %s event received for %s", opts.match, opts.data.interaction)
                if opts.match == "MaxaAIRequestFinished" and opts.data.interaction ~= "chat" then
                    return log:trace("Skipping RequestFinished event received for non-chat interaction")
                end
                local chat_module = require("maxa.interactions.chat")
                local bufnr = opts.data.bufnr
                if not bufnr then
                    return log:trace("No bufnr found in event data")
                end
                local chat = chat_module.buf_get_chat(bufnr) --[[@as MaxaAI.History.Chat]]
                if chat then
                    if opts.match == "MaxaAIToolsFinished" then
                        return require("maxa.interactions.chat.tools.builtin.runtime.context_injector").flush_before(
                            chat,
                            function(flushed_chat)
                                self.storage:save_chat(flushed_chat)
                            end
                        )
                    end
                    self.storage:save_chat(chat)
                end
            end
        end),
    })

    vim.api.nvim_create_autocmd("User", {
        pattern = "MaxaAIChatSubmitted",
        group = group,
        callback = vim.schedule_wrap(function(opts)
            log:trace("Chat submitted event received")
            local chat_module = require("maxa.interactions.chat")
            local bufnr = opts.data.bufnr
            local chat = chat_module.buf_get_chat(bufnr) --[[@as MaxaAI.History.Chat]]
            if not chat then
                return
            end

            -- Handle title generation/refresh
            local should_generate, is_refresh = self.title_generator:should_generate(chat)
            if should_generate then
                self.title_generator:generate(chat, function(generated_title, error)
                    if error then
                        self.ui:update_chat_title(chat) -- revert to base title
                        vim.notify("Failed to generate title: " .. error, vim.log.levels.WARN)
                        return
                    end
                    if type(self.opts.title_generation_opts.format_title) == "function" then
                        generated_title = self.opts.title_generation_opts.format_title(generated_title)
                    end
                    if generated_title and generated_title ~= "" then
                        -- Always update buffer title for feedback
                        self.ui:_set_buf_title(chat.bufnr, generated_title)

                        -- Only update chat.opts.title and save for real titles (not feedback)
                        if generated_title ~= "Deciding title..." and generated_title ~= "Refreshing title..." then
                            if is_refresh then
                                chat.opts.title_refresh_count = (chat.opts.title_refresh_count or 0) + 1
                            end

                            local previous_title = chat.opts.title or chat.title
                            chat.opts.title = generated_title
                            emit_title_changed(chat, generated_title, previous_title)

                            if self.opts.auto_save then
                                self.storage:save_chat(chat)
                            end
                        end
                    else
                        self.ui:update_chat_title(chat)
                    end
                end, is_refresh)
            end

            if self.opts.auto_save then
                self.storage:save_chat(chat)
            end
        end),
    })

    vim.api.nvim_create_autocmd("User", {
        pattern = "MaxaAIChatCleared",
        group = group,
        callback = vim.schedule_wrap(function(opts)
            log:trace("Chat cleared event received")

            local chat_module = require("maxa.interactions.chat")
            local bufnr = opts.data.bufnr
            local chat = chat_module.buf_get_chat(bufnr) --[[@as MaxaAI.History.Chat]]
            if not chat then
                return
            end
            if self.opts.delete_on_clearing_chat then
                log:trace("Deleting cleared chat from storage: %s", chat.opts.save_id)
                self.storage:delete_chat(chat.opts.save_id)
            end

            -- Reset chat state
            chat.opts.title = nil
            local core = require("maxa.session.history_core")
            chat.opts.save_id = core.is_unsavable_save_id(chat.opts.save_id) and core.make_unsavable_save_id("cleared")
                or utils.generate_save_id({ history_dir = self.storage and self.storage.base_path })
            require("maxa.session.agent_identity").reidentify(chat)
            chat._meta.last_dialogue_at = nil
            log:trace("Generated new save_id after clear: %s", chat.opts.save_id)

            -- Update title for new chat
            self.ui:update_chat_title(chat)
        end),
    })
end

function History:_setup_keymaps()
    local function form_modes(v)
        if type(v) == "string" then
            return {
                n = v,
            }
        end
        return v
    end

    local keymaps = {
        ["Saved Chats"] = {
            modes = form_modes(self.opts.keymap),
            description = self.opts.keymap_description,
            callback = function(_)
                self.ui:open_saved_chats(self.opts.chat_filter)
            end,
        },
        ["Save Current Chat"] = {
            modes = form_modes(self.opts.save_chat_keymap),
            description = self.opts.save_chat_keymap_description,
            callback = function(chat)
                if not chat then
                    return
                end
                self.storage:save_chat(chat)
                log:debug("Saved current chat")
            end,
        },
    }

    local cc_config = require("maxa.config")
    -- Add all keymaps to maxa_ai
    for name, keymap in pairs(keymaps) do
        cc_config.interactions.chat.keymaps[name] = keymap
    end
end

---@type MaxaAI.Extension
return {
    ---@param opts MaxaAI.History.Opts
    setup = function(opts)
        if not history_instance or vim.fn.exists(":MaxaHistory") ~= 2 then
            -- Initialize logging first
            opts = vim.tbl_deep_extend("force", default_opts, opts or {})
            log.setup_logging(opts.enable_logging)
            history_instance = History.new(opts)
            log:debug("History extension setup successfully")
        end

    end,
    exports = {
        ---Get the base path of the storage
        ---@return string?
        get_location = function()
            if not history_instance then
                return
            end
            return history_instance.storage:get_location()
        end,
        ---Save a chat to storage falling back to the last chat if none is provided
        ---@param chat? MaxaAI.History.Chat
        save_chat = function(chat)
            if not history_instance then
                return
            end
            history_instance.storage:save_chat(chat)
        end,

        ---Browse chats with custom filter function
        ---@param filter_fn? fun(chat_data: MaxaAI.History.ChatIndexData): boolean Optional filter function
        browse_chats = function(filter_fn)
            if not history_instance then
                return
            end
            history_instance.ui:open_saved_chats(filter_fn)
        end,

        --- Loads chats metadata from the index with optional filtering
        ---@param filter_fn? fun(chat_data: MaxaAI.History.ChatIndexData): boolean Optional filter function
        ---@return table<string, MaxaAI.History.ChatIndexData>
        get_chats = function(filter_fn)
            if not history_instance then
                return {}
            end
            return history_instance.storage:get_chats(filter_fn)
        end,

        --- Load a specific chat
        ---@param save_id string ID from chat.opts.save_id to retreive the chat
        ---@return MaxaAI.History.ChatData?
        load_chat = function(save_id)
            if not history_instance then
                return
            end
            return history_instance.storage:load_chat(save_id)
        end,

        ---Restore a saved chat and return the open chat instance.
        ---@param save_id string ID from chat.opts.save_id to restore
        ---@return MaxaAI.History.Chat? chat
        ---@return string? error
        restore_chat = function(save_id)
            if not history_instance then
                return nil, "history_not_initialized"
            end
            if type(save_id) ~= "string" or save_id == "" then
                return nil, "invalid_save_id"
            end
            local maxa_ai = require("maxa")
            local chat_module = require("maxa.interactions.chat")
            local opened_chats = chat_module.buf_get_chat()
            if type(opened_chats) == "table" then
                for _, data in ipairs(opened_chats) do
                    local chat = data.chat or data
                    if chat and chat.opts and chat.opts.save_id == save_id then
                        if chat.ui and type(chat.ui.open) == "function" then
                            local active_chat = maxa_ai.last_chat()
                            if active_chat and active_chat ~= chat and active_chat.ui and type(active_chat.ui.is_active) == "function" and active_chat.ui:is_active() then
                                active_chat.ui:hide()
                            end
                            chat.ui:open()
                        end
                        return chat, nil
                    end
                end
            end
            local full_chat = history_instance.storage:load_chat(save_id)
            if not full_chat then
                return nil, "history_not_found"
            end
            local chat = history_instance.ui:create_chat(full_chat)
            if not chat then
                return nil, "restore_failed"
            end
            return chat, nil
        end,

        ---Create a Chat directly from saved history data.
        ---@param chat_data MaxaAI.History.ChatData
        ---@return MaxaAI.History.Chat|nil
        create_chat = function(chat_data, display_opts)
            if not history_instance then
                return nil
            end
            return history_instance.ui:create_chat(chat_data, display_opts)
        end,

        ---Delete a chat
        ---@param save_id string ID from chat.opts.save_id to retreive the chat
        ---@return boolean
        delete_chat = function(save_id)
            if not history_instance then
                return false
            end
            return history_instance.storage:delete_chat(save_id)
        end,

        ---Duplicate a chat
        ---@param save_id string ID from chat.opts.save_id to duplicate
        ---@param new_title? string Optional new title (defaults to "Title (1)")
        ---@return string|nil new_save_id The new chat's save_id if successful
        duplicate_chat = function(save_id, new_title)
            if not history_instance then
                return nil
            end
            return history_instance.storage:duplicate_chat(save_id, new_title)
        end,
    },
    --for testing
    History = History,
}
