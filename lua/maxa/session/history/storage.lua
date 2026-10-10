---@class MaxaAI.History.Storage
---@field base_path string Base directory path
---@field index_path string Path to index file
---@field chats_dir string Path to chats directory
---@field expiration_days number Number of days after which chats are deleted
local Storage = {}

local log = require("maxa.session.history.log")
local utils = require("maxa.session.history.utils")
local project_registry = require("maxa.session.history.project_registry")
local transfer = require("maxa.session.history.transfer")

-- ═══════════════════════════════════════════════════════════════
-- Project directory detection (integrated from history_storage hook)
-- ═══════════════════════════════════════════════════════════════

--- Detect project history dir for a given path
---@param path string|number file path or buffer number
---@return string|nil project-level history directory
local function get_project_history_dir_for_path(path)
    local project_root = vim.fs.root(path, { ".maxa" })
    if project_root then
        local history_dir = project_root .. "/.maxa/history"
        if vim.fn.isdirectory(history_dir) == 0 then
            vim.fn.mkdir(history_dir, "p")
        end
        pcall(project_registry.record, project_root)
        return history_dir
    end
    return nil
end

-- ═══════════════════════════════════════════════════════════════
-- UTF-8 sanitization (integrated from history_storage hook)
-- ═══════════════════════════════════════════════════════════════

--- Replace non-UTF-8 bytes with U+FFFD (replacement character)
---@param str string
---@return string
local function sanitize_utf8(str)
    if not str or str == "" then
        return str
    end
    if not str:match("[\128-\255]") then
        return str
    end
    local result = {}
    local i = 1
    local len = #str
    while i <= len do
        local byte = str:byte(i)
        if byte < 128 then
            result[#result + 1] = str:sub(i, i)
            i = i + 1
        elseif byte >= 194 and byte <= 223 then
            if i + 1 <= len then
                local b2 = str:byte(i + 1)
                if b2 >= 128 and b2 <= 191 then
                    result[#result + 1] = str:sub(i, i + 1)
                    i = i + 2
                else
                    result[#result + 1] = "\xEF\xBF\xBD"
                    i = i + 1
                end
            else
                result[#result + 1] = "\xEF\xBF\xBD"
                i = i + 1
            end
        elseif byte >= 224 and byte <= 239 then
            if i + 2 <= len then
                local b2, b3 = str:byte(i + 1), str:byte(i + 2)
                if b2 >= 128 and b2 <= 191 and b3 >= 128 and b3 <= 191 then
                    if byte == 224 and b2 < 160 then
                        result[#result + 1] = "\xEF\xBF\xBD"
                        i = i + 1
                    elseif byte == 237 and b2 > 159 then
                        result[#result + 1] = "\xEF\xBF\xBD"
                        i = i + 1
                    else
                        result[#result + 1] = str:sub(i, i + 2)
                        i = i + 3
                    end
                else
                    result[#result + 1] = "\xEF\xBF\xBD"
                    i = i + 1
                end
            else
                result[#result + 1] = "\xEF\xBF\xBD"
                i = i + 1
            end
        elseif byte >= 240 and byte <= 244 then
            if i + 3 <= len then
                local b2, b3, b4 = str:byte(i + 1), str:byte(i + 2), str:byte(i + 3)
                if b2 >= 128 and b2 <= 191 and b3 >= 128 and b3 <= 191 and b4 >= 128 and b4 <= 191 then
                    if byte == 240 and b2 < 144 then
                        result[#result + 1] = "\xEF\xBF\xBD"
                        i = i + 1
                    elseif byte == 244 and b2 > 143 then
                        result[#result + 1] = "\xEF\xBF\xBD"
                        i = i + 1
                    else
                        result[#result + 1] = str:sub(i, i + 3)
                        i = i + 4
                    end
                else
                    result[#result + 1] = "\xEF\xBF\xBD"
                    i = i + 1
                end
            else
                result[#result + 1] = "\xEF\xBF\xBD"
                i = i + 1
            end
        else
            result[#result + 1] = "\xEF\xBF\xBD"
            i = i + 1
        end
    end
    return table.concat(result)
end

--- Recursively sanitize all string fields in messages
---@param messages table[]
local function sanitize_messages_utf8(messages)
    if not messages then
        return
    end
    for _, msg in ipairs(messages) do
        if type(msg.content) == "string" then
            msg.content = sanitize_utf8(msg.content)
        end
        if msg.tools and msg.tools.calls then
            for _, call in ipairs(msg.tools.calls) do
                if call["function"] and type(call["function"].arguments) == "string" then
                    call["function"].arguments = sanitize_utf8(call["function"].arguments)
                end
            end
        end
    end
end

--- Sanitize invalid tool call arguments in messages
---@param messages table[]
local function sanitize_tool_call_arguments(messages)
    if not messages then
        return
    end
    for _, msg in ipairs(messages) do
        if msg.role == "llm" and msg.tools and msg.tools.calls then
            for _, call in ipairs(msg.tools.calls) do
                if call["function"] and call["function"].arguments then
                    local args = call["function"].arguments
                    if type(args) == "string" and args ~= "" then
                        local ok, decoded = pcall(vim.json.decode, args)
                        if not ok or type(decoded) ~= "table" then
                            call["function"].arguments = "{}"
                        end
                    elseif type(args) ~= "string" then
                        local ok, encoded = pcall(vim.json.encode, args)
                        if ok then
                            call["function"].arguments = encoded
                        else
                            call["function"].arguments = "{}"
                        end
                    end
                end
            end
        end
    end
end

--- Smart project history dir detection
--- Project-scoped history should follow Neovim's current working directory first.
--- Buffer paths are only fallbacks for cases where cwd is unavailable or not project-scoped.
---@return string|nil
local function get_project_history_dir()
    -- 1. Prefer cwd so dashboard/empty-buffer sessions stay scoped to the project
    -- used to launch or currently drive Neovim, instead of global recent files.
    local cwd = vim.uv.cwd() or vim.fn.getcwd(-1, -1)
    if cwd and cwd ~= "" then
        local dir = get_project_history_dir_for_path(cwd)
        if dir then
            return dir
        end
    end

    -- 2. Fallback: current real file buffer
    local current_buf = vim.api.nvim_get_current_buf()
    local current_name = vim.api.nvim_buf_get_name(current_buf)
    local current_ft = vim.bo[current_buf].filetype
    local current_bt = vim.bo[current_buf].buftype

    if current_bt == "" and current_ft ~= "maxa_ai" and current_name ~= "" then
        local dir = get_project_history_dir_for_path(current_name)
        if dir then
            return dir
        end
    end

    -- 3. Fallback: loaded real file buffers
    local buffers = vim.api.nvim_list_bufs()
    for _, bufnr in ipairs(buffers) do
        if vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_is_loaded(bufnr) then
            local bt = vim.bo[bufnr].buftype
            local ft = vim.bo[bufnr].filetype
            local name = vim.api.nvim_buf_get_name(bufnr)
            if bt == "" and ft ~= "maxa_ai" and name ~= "" and not name:match("^%w+://") then
                local dir = get_project_history_dir_for_path(name)
                if dir then
                    return dir
                end
            end
        end
    end

    return nil
end

function Storage.new(opts)
    -- Project directory detection: override dir_to_save if in a project
    local project_history_dir = get_project_history_dir()
    if project_history_dir then
        opts.dir_to_save = project_history_dir
    end

    local self = setmetatable({}, {
        __index = Storage,
    })

    self.base_path = opts.dir_to_save:gsub("/+$", "")
    self.index_path = self.base_path .. "/index.json"
    self.chats_dir = self.base_path .. "/chats"
    self.expiration_days = opts.expiration_days or 0
    log:trace("Initializing storage with base path: %s, expiration: %d days", self.base_path, self.expiration_days)
    -- Ensure storage directories exist
    self:_ensure_storage_dirs()
    -- Clean expired chats on startup
    self:clean_expired_chats()

    return self --[[@as MaxaAI.History.Storage]]
end

---Clean expired chats based on expiration_days setting
---@private
function Storage:clean_expired_chats()
    -- Skip if expiration is disabled
    if self.expiration_days <= 0 then
        log:trace("Chat expiration disabled, skipping cleanup")
        return
    end

    log:trace("Checking for expired chats (older than %d days)", self.expiration_days)
    local index = self:get_chats()
    local now = os.time()
    local expired_count = 0

    -- Calculate expiration threshold in seconds
    local expiration_threshold = now - (self.expiration_days * 24 * 60 * 60)

    -- Check each chat
    for id, chat_meta in pairs(index) do
        if chat_meta.updated_at and chat_meta.updated_at < expiration_threshold then
            log:trace("Deleting expired chat: %s (last updated: %s)", id, os.date("%Y-%m-%d", chat_meta.updated_at))
            if self:delete_chat(id) then
                expired_count = expired_count + 1
            end
        end
    end

    if expired_count > 0 then
        log:debug("Cleaned up %d expired chats", expired_count)
    end
end

---Get the base path of the storage
---@return string
function Storage:get_location()
    return self.base_path
end

function Storage:_ensure_storage_dirs()
    local Path = require("plenary.path")

    -- Create base directory
    local base_dir = Path:new(self.base_path)
    if not base_dir:exists() then
        log:trace("Creating base directory: %s", self.base_path)
        base_dir:mkdir({ parents = true })
    end

    -- Create chats directory
    local chats_dir = Path:new(self.chats_dir)
    if not chats_dir:exists() then
        log:trace("Creating chats directory: %s", self.chats_dir)
        chats_dir:mkdir({ parents = true })
    end

    -- Initialize index file if it doesn't exist
    local index_path = Path:new(self.index_path)
    if not index_path:exists() then
        log:trace("Initializing empty index file: %s", self.index_path)
        -- Initialize with empty object, not array, since we use it as a key-value store
        local empty_index = vim.empty_dict()
        local result = utils.write_json(self.index_path, empty_index)
        if not result.ok then
            log:error("Failed to initialize index file: %s", result.error)
        end
    end

end

---@param chat_data MaxaAI.History.ChatData
---@return {ok: boolean, error: string|nil}
function Storage:_save_chat_to_file(chat_data)
    local chat_path = self.chats_dir .. "/" .. chat_data.save_id .. ".json"
    log:trace("Saving chat to file: %s", chat_path)
    return utils.write_json(chat_path, chat_data)
end

---@param chat_data MaxaAI.History.ChatData
---@return {ok: boolean, error: string|nil}
function Storage:_update_index_entry(chat_data)
    log:trace("Updating index entry for chat: %s", chat_data.save_id)
    -- Read current index
    local index_result = utils.read_json(self.index_path)
    if not index_result.ok then
        return { ok = false, error = "Failed to read index: " .. index_result.error }
    end

    -- Ensure we have a table to work with
    local index = index_result.data or {}

    -- Calculate message count and token estimate
    local message_count = #(chat_data.messages or {})
    local total_chars = 0
    for _, msg in ipairs(chat_data.messages or {}) do
        total_chars = total_chars + #(msg.content or "")
    end
    local token_estimate = math.floor(total_chars / 4)

    -- Update index with enhanced metadata
    index[chat_data.save_id] = {
        save_id = chat_data.save_id,
        title = chat_data.title,
        updated_at = chat_data.updated_at,
        model = chat_data.settings and chat_data.settings.model or "unknown",
        adapter = chat_data.adapter or "unknown",
        message_count = message_count,
        token_estimate = token_estimate,
        cwd = chat_data.cwd,
        project_root = chat_data.project_root,
        compact_protected_prefix_count = chat_data.compact_protected_prefix_count or 0,
        agent = require("maxa.session.agent_identity").index_fields(chat_data).agent,
        last_dialogue_at = chat_data._meta and chat_data._meta.last_dialogue_at,
        session_trace = chat_data._meta and chat_data._meta.session_trace,
    }

    -- Write updated index
    return utils.write_json(self.index_path, utils.remove_functions(index))
end

---Load all chats from storage (index only) with optional filtering
---@param filter_fn? fun(chat_data: MaxaAI.History.ChatIndexData): boolean Optional filter function
---@return table<string, MaxaAI.History.ChatIndexData>
function Storage:get_chats(filter_fn)
    -- Dynamic directory switching: check if project dir changed
    local project_history_dir = get_project_history_dir()
    if project_history_dir and self.base_path ~= project_history_dir then
        self.base_path = project_history_dir
        self.chats_dir = project_history_dir .. "/chats"
        self.index_path = project_history_dir .. "/index.json"
        self:_ensure_storage_dirs()
    end

    log:trace("Loading chat index")
    local result = utils.read_json(self.index_path)
    if not result.ok then
        if result.error:match("does not exist") then
            log:trace("Index file does not exist, initializing storage")
            self:_ensure_storage_dirs()
            return {}
        else
            log:error("Failed to read chat index: %s", result.error)
            return {}
        end
    end

    local all_chats = result.data or {}

    -- If no filter provided, return all chats
    if not filter_fn then
        return all_chats
    end

    -- Apply filter and return filtered chats
    local filtered_chats = {}
    for id, chat_data in pairs(all_chats) do
        if filter_fn(chat_data) then
            filtered_chats[id] = chat_data
        end
    end

    return filtered_chats
end

---Load a specific chat by ID
---@param id string
---@return MaxaAI.History.ChatData|nil
function Storage:load_chat(id)
    local chat_path = self.chats_dir .. "/" .. id .. ".json"
    log:trace("Loading chat from: %s", chat_path)
    local result = utils.read_json(chat_path)

    if not result.ok then
        if not result.error:match("does not exist") then
            log:error("Failed to load chat: %s", result.error)
        end
        return nil
    end

    return result.data --[[@as MaxaAI.History.ChatData]]
end

---Validate chat object for required fields and structure
---@param chat table
---@return boolean, string?
local function validate_chat_object(chat)
    if not chat then
        return false, "chat object is nil"
    end
    if type(chat) ~= "table" then
        return false, "chat must be a table"
    end
    if type(chat.opts) ~= "table" then
        return false, "chat.opts must be a table"
    end
    if type(chat.opts.save_id) ~= "string" then
        return false, "chat.opts.save_id must be a string"
    end
    -- Check for path traversal characters in save_id
    if chat.opts.save_id:match("[/\\]") then
        return false, "invalid characters in save_id"
    end
    -- Validate messages structure if present
    if chat.messages ~= nil then
        if type(chat.messages) ~= "table" then
            return false, "messages must be a table"
        end
        for i, msg in ipairs(chat.messages) do
            if type(msg) ~= "table" then
                return false, string.format("message %d must be a table", i)
            end
            if msg.role ~= nil and type(msg.role) ~= "string" then
                return false, string.format("message %d role must be a string", i)
            end
            --INFO: For anthropic adapter, tool call results may have non-string content
            -- if msg.content ~= nil and type(msg.content) ~= "string" then
            --     return false, string.format("message %d content must be a string", i)
            -- end
        end
    end
    return true
end

---Save a chat to storage falling back to the last chat if none is provided
---@param chat? MaxaAI.History.Chat
function Storage:save_chat(chat)
    if not chat then
        chat = require("maxa").last_chat() --[[@as MaxaAI.History.Chat]]
        if not chat then
            return
        end
    end

    -- A rewind remains an in-memory branch until a new user message is submitted.
    if chat._session_rewind_pending then
        return
    end

    -- Maxa-controlled temporary chats use a deliberately invalid save_id
    -- (contains `/`) so MaxaAI can run normally without persisting them.
    -- Skip these silently; keep validation errors for all other invalid IDs.
    local ok_history_core, history_core = pcall(require, "maxa.session.history_core")
    if ok_history_core
        and history_core
        and type(history_core.is_unsavable_save_id) == "function"
        and chat.opts
        and history_core.is_unsavable_save_id(chat.opts.save_id)
    then
        log:trace("Skipping unsavable temporary chat: %s", chat.opts.save_id)
        return
    end

    -- Validate chat object structure
    local valid, err = validate_chat_object(chat)
    if not valid then
        log:error("Cannot save chat: %s", err)
        return
    end

    -- Dynamic directory switching before save
    local project_history_dir = get_project_history_dir()
    if project_history_dir and self.base_path ~= project_history_dir then
        self.base_path = project_history_dir
        self.chats_dir = project_history_dir .. "/chats"
        self.index_path = project_history_dir .. "/index.json"
        self:_ensure_storage_dirs()
    end

    log:trace("Saving chat: %s", chat.opts.save_id)
    pcall(function()
        require("maxa.session.status.state").persist_chat_status(chat, chat.bufnr)
    end)
    local cwd = chat.opts.cwd or vim.uv.cwd() or vim.fn.getcwd(-1, -1)
    ---@type MaxaAI.History.ChatData
    local protected_prefix_count = chat._compact_protected_prefix_count
        or (chat.opts and chat.opts.compact_protected_prefix_count)
        or 0

    local messages = chat.messages or {}
    local ok_session, history_session = pcall(require, "maxa.session.history_session")
    if ok_session and type(history_session.strip_runtime_control_messages) == "function" then
        messages = history_session.strip_runtime_control_messages(messages)
    end

    local meta = vim.deepcopy(chat._meta or {})
    meta.notify_when_done = nil

    local chat_data = {
        save_id = chat.opts.save_id,
        title = chat.opts.title,
        messages = messages,
        settings = chat.settings or {},
        _meta = meta,
        adapter = chat.adapter and chat.adapter.name or "unknown",
        updated_at = os.time(),
        context_items = chat.context_items or {},
        schemas = (chat.tool_registry and chat.tool_registry.schemas) or {},
        in_use = (chat.tool_registry and chat.tool_registry.in_use) or {},
        cycle = chat.cycle or 1,
        title_refresh_count = chat.opts.title_refresh_count or 0,
        compact_protected_prefix_count = protected_prefix_count,
        opts = {
            compact_protected_prefix_count = protected_prefix_count,
        },
        cwd = cwd,
        project_root = utils.find_project_root(cwd),
    }

    -- ─── Sanitize before serialization ────────────────────────────
    sanitize_tool_call_arguments(chat_data.messages)
    sanitize_messages_utf8(chat_data.messages)

    -- Save chat to file
    local save_result = self:_save_chat_to_file(utils.remove_functions(chat_data))
    if not save_result.ok then
        log:error("Failed to save chat: %s", save_result.error)
    end

    -- Update index
    local index_result = self:_update_index_entry(chat_data)
    if not index_result.ok then
        log:error("Failed to update index: %s", index_result.error)
    end

end

---Delete a chat from storage
---@param id string
---@return boolean
function Storage:delete_chat(id)
    if not id then
        log:error("Cannot delete chat: missing id")
        return false
    end

    log:debug("Deleting chat: %s", id)
    -- Delete the chat file
    local chat_path = self.chats_dir .. "/" .. id .. ".json"
    local delete_result = utils.delete_file(chat_path)
    if not delete_result.ok then
        log:error("Failed to delete chat file: %s", delete_result.error)
    end

    -- Remove from index
    local index_result = utils.read_json(self.index_path)
    if not index_result.ok then
        log:error("Failed to read index for deletion: %s", index_result.error)
        return false
    end

    -- Ensure we have a table to work with
    local index = index_result.data or {}

    -- Remove entry from index
    index[id] = nil

    -- Save updated index
    local write_result = utils.write_json(self.index_path, index)
    if not write_result.ok then
        log:error("Failed to update index after deletion: %s", write_result.error)
        return false
    end
    return true
end

---Get the most recently updated chat from storage with optional filtering
---@param filter_fn? fun(chat_data: MaxaAI.History.ChatIndexData): boolean Optional filter function
---@return MaxaAI.History.ChatData|nil
function Storage:get_last_chat(filter_fn)
    log:debug("Getting most recent chat")
    local index = self:get_chats(filter_fn)
    if vim.tbl_isempty(index) then
        return nil
    end

    -- Find the most recently updated chat
    local most_recent = nil
    local most_recent_time = 0

    for id, chat_meta in pairs(index) do
        if chat_meta.updated_at and chat_meta.updated_at > most_recent_time then
            most_recent = id
            most_recent_time = chat_meta.updated_at
        end
    end

    -- If we found a recent chat, load and return it
    if most_recent then
        log:trace("Found most recent chat: %s", most_recent)
        return self:load_chat(most_recent)
    end

    return nil
end

---Rename a chat in storage
---@param save_id string The chat ID to rename
---@param new_title string The new title for the chat
---@return boolean success
function Storage:rename_chat(save_id, new_title)
    log:trace("Renaming chat %s to: %s", save_id, new_title)
    local index = self:get_chats()
    if not index[save_id] then
        log:error("Chat %s not found in index", save_id)
        return false
    end

    -- Update index
    index[save_id].title = new_title
    index[save_id].updated_at = os.time()
    local result = utils.write_json(self.index_path, index)
    if not result.ok then
        log:error("Failed to update index with new title: %s", result.error)
        return false
    end

    -- Update chat data
    local chat_path = self.chats_dir .. "/" .. save_id .. ".json"
    local chat_result = utils.read_json(chat_path)
    if chat_result.ok then
        chat_result.data.title = new_title
        chat_result.data.updated_at = os.time()
        result = utils.write_json(chat_path, chat_result.data)
        if not result.ok then
            log:error("Failed to update chat file with new title: %s", result.error)
            return false
        end
    end

    log:debug("Successfully renamed chat %s to: %s", save_id, new_title)
    return true
end

---Duplicate a chat in storage with a new title
---@param original_id string The original chat ID to duplicate
---@param new_title? string Optional new title (defaults to "Title (1)")
---@return string|nil new_save_id The new chat's save_id if successful
function Storage:duplicate_chat(original_id, new_title)
    log:trace("Duplicating chat: %s", original_id)

    -- Load original chat
    local original_chat = self:load_chat(original_id)
    if not original_chat then
        log:error("Cannot duplicate: original chat not found: %s", original_id)
        return nil
    end

    -- Generate new save_id
    local new_save_id = utils.generate_save_id({ history_dir = self.base_path })

    -- Generate appropriate title if not provided
    if not new_title then
        local original_title = original_chat.title or "Untitled"
        new_title = original_title .. " (1)"
    end

    -- Create duplicated chat data
    local duplicated_chat = vim.deepcopy(original_chat)
    duplicated_chat.save_id = new_save_id
    duplicated_chat.title = new_title
    duplicated_chat.updated_at = os.time()
    duplicated_chat.title_refresh_count = 0 -- Reset refresh count for new chat
    require("maxa.session.agent_identity").reidentify(duplicated_chat, true)

    -- Save duplicated chat
    local save_result = self:_save_chat_to_file(duplicated_chat)
    if not save_result.ok then
        log:error("Failed to save duplicated chat: %s", save_result.error)
        return nil
    end

    -- Update index
    local index_result = self:_update_index_entry(duplicated_chat)
    if not index_result.ok then
        log:error("Failed to update index for duplicated chat: %s", index_result.error)
        return nil
    end

    log:debug("Successfully duplicated chat %s -> %s", original_id, new_save_id)
    return new_save_id
end

---@private
function Storage:_refresh_project_history_dir()
    local project_history_dir = get_project_history_dir()
    if project_history_dir and self.base_path ~= project_history_dir then
        self.base_path = project_history_dir
        self.chats_dir = project_history_dir .. "/chats"
        self.index_path = project_history_dir .. "/index.json"
        self:_ensure_storage_dirs()
    end
end

---@param save_id string
---@param target_project_root string
---@param mode "copy"|"move"
---@param opts? {title?: string}
---@return table|nil result
---@return string|nil err
function Storage:transfer_chat_to_project(save_id, target_project_root, mode, opts)
    opts = opts or {}
    self:_refresh_project_history_dir()
    return transfer.transfer_chat({
        mode = mode,
        source_history_dir = self.base_path,
        source_save_id = save_id,
        target_project_root = target_project_root,
        title = opts.title,
    })
end

---@param save_id string
---@param target_project_root string
---@param opts? {title?: string}
---@return table|nil result
---@return string|nil err
function Storage:copy_chat_to_project(save_id, target_project_root, opts)
    return self:transfer_chat_to_project(save_id, target_project_root, "copy", opts)
end

---@param save_id string
---@param target_project_root string
---@param opts? {title?: string}
---@return table|nil result
---@return string|nil err
function Storage:move_chat_to_project(save_id, target_project_root, opts)
    return self:transfer_chat_to_project(save_id, target_project_root, "move", opts)
end

return Storage
