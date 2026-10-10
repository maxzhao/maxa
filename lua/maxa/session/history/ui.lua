local runtime_state = require("maxa.state")
local api = vim.api
local config = require("maxa.config")
local log = require("maxa.session.history.log")
local project_registry = require("maxa.session.history.project_registry")
local utils = require("maxa.session.history.utils")

--- Sanitize invalid tool_call arguments in messages
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
            local ok, _ = pcall(vim.json.decode, args)
            if not ok then
              call["function"].arguments = "{}"
            end
          elseif type(args) == "string" and args == "" then
            call["function"].arguments = "{}"
          end
        end
      end
    end
  end
end

---@class MaxaAI.History.UI
---@field storage MaxaAI.History.Storage
---@field title_generator MaxaAI.History.TitleGenerator
---@field default_buf_title string
---@field picker MaxaAI.History.Pickers
---@field picker_keymaps table
local UI = {}

---@param opts MaxaAI.History.Opts
---@param storage MaxaAI.History.Storage
---@param title_generator MaxaAI.History.TitleGenerator
---@return MaxaAI.History.UI
function UI.new(opts, storage, title_generator)
    local self = setmetatable({}, {
        __index = UI,
    })

    self.storage = storage
    self.title_generator = title_generator
    self.default_buf_title = opts.default_buf_title
    self.picker = opts.picker
    self.picker_keymaps = opts.picker_keymaps

    log:trace("Initialized UI with picker: %s", opts.picker)
    return self --[[@as MaxaAI.History.UI]]
end

---Update chat title with optional suffix
---@param chat MaxaAI.History.Chat
---@param suffix? string Optional suffix to append to title
---@param force? boolean
function UI:update_chat_title(chat, suffix, force)
    log:trace("Updating chat title for: %s", chat.opts.save_id or "N/A")

    local base_title = chat.opts.title or (self.default_buf_title .. tostring(chat.id))

    if suffix then
        local full_title = force and suffix or (base_title .. " " .. suffix)
        self:_set_buf_title(chat.bufnr, full_title)
    else
        self:_set_buf_title(chat.bufnr, base_title)
    end
end

---Method for setting buffer title with retry
---@param bufnr number
---@param title string|string[]
---@param attempt? number
function UI:_set_buf_title(bufnr, title, attempt)
    attempt = attempt or 0
    log:trace("Setting buffer title (attempt %d) for buffer %d", attempt, bufnr)

    vim.schedule(function()
        ---Takes a array of strings and justifies them to fit the available width
        ---@param str_array string[]
        ---@return string
        local function justify_strings(str_array)
            -- Validate input
            if #str_array == 0 then
                return ""
            end
            if #str_array == 1 then
                return str_array[1]
            end

            -- Get the window ID for this buffer
            local win_id = vim.fn.bufwinid(bufnr)
            if win_id == -1 then
                log:trace("No window found for buffer %d, falling back to simple concat", bufnr)
                return table.concat(str_array, " ")
            end

            -- Get available width (subtract 10 for the sparkle and some padding, any file icons in winbar)
            local width = vim.api.nvim_win_get_width(win_id) - 10

            -- Calculate total string length
            local total_len = 0
            for _, str in ipairs(str_array) do
                if type(str) ~= "string" then
                    log:warn("Non-string value in title array, falling back to simple concat")
                    return table.concat(str_array, " ")
                end
                total_len = total_len + vim.api.nvim_strwidth(str)
            end

            -- Calculate remaining space and gaps
            local remaining_space = math.max(0, width - total_len)
            local num_gaps = #str_array - 1
            if num_gaps <= 0 or remaining_space <= 0 then
                return table.concat(str_array, " ")
            end

            -- Calculate even gap size and extra spaces to distribute
            local gap_size = math.floor(remaining_space / num_gaps)
            local extra_spaces = remaining_space % num_gaps

            -- Construct the justified string
            local result = {}
            for i, str in ipairs(str_array) do
                table.insert(result, str)
                if i < #str_array then
                    -- Add gap and distribute extra spaces
                    table.insert(result, string.rep(" ", gap_size + (i <= extra_spaces and 1 or 0)))
                end
            end

            -- Combine and truncate if necessary
            local final_result = table.concat(result)
            if vim.api.nvim_strwidth(final_result) > width then
                final_result = vim.fn.strcharpart(final_result, 0, width - 1) .. "…"
            end

            return final_result
        end

        -- Process title based on type
        local final_title
        if type(title) == "table" then
            final_title = justify_strings(title)
        else
            final_title = tostring(title)
        end

        local icon = "✨ "
        -- throws error if buffer with same name already exists so we add a counter to the title
        local success, err = pcall(function()
            local _title = final_title .. (attempt > 0 and " (" .. tostring(attempt) .. ")" or "")
            vim.api.nvim_buf_set_name(bufnr, icon .. _title)
            utils.fire("TitleSet", {
                bufnr = bufnr,
                title = _title,
            })
        end)

        if not success then
            if attempt > 10 then
                log:trace("Failed to set buffer title after 10 attempts: %s", err)
                vim.notify("Failed to set buffer title: " .. err, vim.log.levels.ERROR)
                return
            end
            log:trace("Title collision, retrying with attempt %d", attempt + 1)
            self:_set_buf_title(bufnr, final_title, attempt + 1)
        else
            log:trace("Successfully set buffer title for buffer %d, %s", bufnr, final_title)
        end
    end)
end

---Format chat items for display
---@param items_data table<string,MaxaAI.History.ChatIndexData> Raw items from storage
---@return MaxaAI.History.EntryItem[] Formatted items
local function format_items(items_data)
    local items = {}

    for _, chat_item in pairs(items_data) do
        local save_id = chat_item.save_id
        table.insert(
            items,
            vim.tbl_extend("keep", {
                save_id = save_id,
                name = chat_item.title or save_id,
                title = chat_item.title or save_id,
                updated_at = chat_item.updated_at or 0,
            }, chat_item)
        )
    end
    -- Sort items by updated_at in descending order
    table.sort(items, function(a, b)
        return a.updated_at > b.updated_at
    end)

    return items
end

---Open items in picker
---@param items_data table<string,MaxaAI.History.ChatIndexData> Raw items from storage
---@param handlers MaxaAI.History.UIHandlers Handlers for item actions
---@param current_item_id? string Current item ID for highlighting
local function format_transfer_result(result)
    return string.format(
        "Chat %s to %s as %s",
        result.mode == "move" and "moved" or "copied",
        result.target_project_root,
        result.target_save_id
    )
end

function UI:_select_target_project(callback)
    local current_root = self.storage.base_path and self.storage.base_path:match("^(.*)/%.maxa/history$")
    local choices = project_registry.list({ exclude = current_root })
    local manual = { root = "", label = "Enter target project root...", manual = true }
    local items = { manual }
    for _, project in ipairs(choices) do
        project.label = project.root
        table.insert(items, project)
    end

    local function prompt_manual(default)
        vim.ui.input({
            prompt = "Target Maxa project root: ",
            default = default or "",
        }, function(input)
            if not input or vim.trim(input) == "" then
                return
            end
            callback(vim.trim(input))
        end)
    end

    if #items == 1 then
        prompt_manual()
        return
    end

    vim.ui.select(items, {
        prompt = "Select target project",
        format_item = function(item)
            return item.label or item.root
        end,
    }, function(selected)
        if not selected then
            return
        end
        if selected.manual then
            prompt_manual()
        else
            callback(selected.root)
        end
    end)
end

function UI:_transfer_chat_to_project(chat_data, mode, filter_fn)
    if not chat_data or not chat_data.save_id then
        vim.notify("Invalid chat data for transfer", vim.log.levels.ERROR)
        return
    end

    self:_select_target_project(function(target_project_root)
        local result, err = self.storage:transfer_chat_to_project(chat_data.save_id, target_project_root, mode)
        if result then
            vim.notify(format_transfer_result(result), vim.log.levels.INFO)
            self:open_saved_chats(filter_fn)
        else
            vim.notify("Failed to " .. mode .. " chat: " .. (err or "unknown error"), vim.log.levels.ERROR)
        end
    end)
end

function UI:_open_items(items_data, handlers, current_item_id)
    log:trace("Opening chats browser")

    if vim.tbl_isempty(items_data) then
        log:trace("No chats found")
        vim.notify("No chats found", vim.log.levels.INFO)
        return
    end

    -- Runtime colours are a snapshot for this picker, never persisted to storage.
    local items = format_items(items_data)
    local opened = {}
    for _, data in ipairs(require("maxa.interactions.chat").buf_get_chat()) do
        local chat = data.chat
        if chat and not chat._closed and api.nvim_buf_is_valid(chat.bufnr) then
            local opts = chat.opts or {}
            local cwd = opts.cwd or chat.cwd
            local root = cwd and project_registry.normalize_project_root(utils.find_project_root(cwd))
            if root and opts.save_id then
                opened[root] = opened[root] or {}
                opened[root][opts.save_id] = (chat.current_request ~= nil or chat.current_tool ~= nil)
                    and "MaxaHistoryRunning" or "MaxaHistoryOpen"
            end
        end
    end
    for _, item in ipairs(items) do
        local root = item.project_root or (item.cwd and utils.find_project_root(item.cwd))
        root = root and project_registry.normalize_project_root(root)
        item.title_hl = root and opened[root] and opened[root][item.save_id] or nil
    end
    local identity = require("maxa.session.agent_identity")
    local tree = identity.tree(items)
    local tree_items = {}
    local function append(nodes, depth)
        for _, node in ipairs(nodes) do
            local item = vim.tbl_extend("force", {}, node.item, { tree_depth = depth, tree_children = #node.children })
            tree_items[#tree_items + 1] = item
            append(node.children, depth + 1)
        end
    end
    append(tree.roots, 0)
    log:trace("Loaded %d chats", #items)

    -- Load the configured picker module
    log:trace("Using picker: %s", self.picker)

    local resolved_picker
    local is_picker_available, picker_module =
        pcall(require, "maxa.session.history.pickers." .. self.picker)
    if not is_picker_available then
        log:warn("Failed to load picker module '%s', falling back to default", self.picker)
        resolved_picker = require("maxa.session.history.pickers.default")
    else
        resolved_picker = picker_module
    end

    resolved_picker
        :new({
            items = tree_items,
            flat_items = items,
            tree = tree,
            handlers = handlers,
            keymaps = self.picker_keymaps,
            current_item_id = current_item_id,
            title = "Saved Chats",
        })
        :browse()
end

---@param filter_fn? fun(chat_data: MaxaAI.History.ChatIndexData): boolean Optional filter function
function UI:open_saved_chats(filter_fn)
    local maxa_ai = require("maxa")
    local last_chat = maxa_ai.last_chat() --[[@as MaxaAI.History.Chat?]]

    self:_open_items(self.storage:get_chats(filter_fn), {
        on_open = function()
            log:trace("Opening saved chats picker")
            self:open_saved_chats(filter_fn)
        end,
        ---@param chat_data MaxaAI.History.ChatData
        ---@return string[] lines
        on_preview = function(chat_data)
            -- Load full chat data for preview
            local full_chat = self.storage:load_chat(chat_data.save_id)
            if full_chat then
                return self:_get_preview_lines(full_chat)
            else
                log:warn("Failed to load chat data for preview: %s", chat_data.save_id)
                return { "Chat data not available" }
            end
        end,
        ---@param chat_data MaxaAI.History.ChatData
        on_select = function(chat_data)
            self:_handle_on_select(chat_data.save_id)
        end,
        ---@param chat_data MaxaAI.History.ChatData|MaxaAI.History.ChatData[]
        on_delete = function(chat_data)
            -- Handle both single chat and array of chats
            local chats_to_delete = {}
            if type(chat_data) == "table" and chat_data.save_id then
                -- Single chat
                chats_to_delete = { chat_data }
            elseif type(chat_data) == "table" and #chat_data > 0 then
                -- Array of chats
                chats_to_delete = chat_data
            else
                vim.notify("Invalid chat data for deletion", vim.log.levels.ERROR)
                return
            end

            log:trace("Deleting %d chat(s)", #chats_to_delete)

            -- Always ask for confirmation
            local chat_count = #chats_to_delete
            local confirmation_message
            if chat_count == 1 then
                confirmation_message = string.format('Delete chat "%s"?', chats_to_delete[1].title or "Untitled")
            else
                confirmation_message = string.format("Delete %d chats?", chat_count)
            end

            local choice = vim.fn.confirm(confirmation_message, "&Yes\n&No", 2)
            if choice ~= 1 then
                return -- User cancelled
            end

            -- Delete all selected chats
            local deleted_count = 0
            for _, chat in ipairs(chats_to_delete) do
                if self.storage:delete_chat(chat.save_id) then
                    deleted_count = deleted_count + 1
                end
            end

            if deleted_count > 0 then
                local message = deleted_count == 1 and "Chat deleted successfully"
                    or string.format("%d chats deleted successfully", deleted_count)
                vim.notify(message, vim.log.levels.INFO)
                self:open_saved_chats(filter_fn)
            else
                vim.notify("Failed to delete chats", vim.log.levels.ERROR)
            end
        end,
        ---@param chat_data MaxaAI.History.ChatData
        on_rename = function(chat_data)
            log:trace("Renaming chat: %s", chat_data.save_id)

            -- Prompt for new title with current title as default
            vim.ui.input({
                prompt = "Rename to: ",
                default = chat_data.title or "",
            }, function(new_title)
                if not new_title or vim.trim(new_title) == "" then
                    return -- User cancelled or entered empty title
                end

                local success = self.storage:rename_chat(chat_data.save_id, new_title)
                if success then
                    -- Update any open chat buffers with this save_id
                    local found_bufnr = nil
                    for _, bufnr in ipairs(runtime_state.buffers or {}) do
                        local chat = maxa_ai.buf_get_chat(bufnr) --[[@as MaxaAI.History.Chat?]]
                        if chat and chat.opts.save_id == chat_data.save_id then
                            found_bufnr = bufnr
                            chat.opts.title = new_title
                            chat.title = new_title
                            self:_set_buf_title(bufnr, new_title)
                            break
                        end
                    end
                    utils.fire("TitleRenamed", {
                        bufnr = found_bufnr,
                        title = new_title,
                    })
                    vim.notify("Chat renamed successfully", vim.log.levels.INFO)
                    self:open_saved_chats(filter_fn)
                else
                    vim.notify("Failed to rename chat", vim.log.levels.ERROR)
                end
            end)
        end,
        ---@param chat_data MaxaAI.History.ChatData
        on_stats = function(chat_data)
            log:trace("Inspecting chat stats: %s", chat_data.save_id)
            local full_chat = self.storage:load_chat(chat_data.save_id)
            if not full_chat then
                vim.notify("Chat data not available", vim.log.levels.ERROR)
                return
            end
            require("maxa.session.session_status_panel").open_chat_data(full_chat, chat_data.save_id)
        end,
        ---@param chat_data MaxaAI.History.ChatData
        on_copy_to_project = function(chat_data)
            log:trace("Copying chat to project: %s", chat_data.save_id)
            self:_transfer_chat_to_project(chat_data, "copy", filter_fn)
        end,
        ---@param chat_data MaxaAI.History.ChatData
        on_move_to_project = function(chat_data)
            log:trace("Moving chat to project: %s", chat_data.save_id)
            self:_transfer_chat_to_project(chat_data, "move", filter_fn)
        end,
        ---@param chat_data MaxaAI.History.ChatData
        on_duplicate = function(chat_data)
            log:trace("Duplicating chat: %s", chat_data.save_id)

            -- Prompt for new title with current title as default
            vim.ui.input({
                prompt = "Duplicate as: ",
                default = chat_data.title or "",
            }, function(new_title)
                -- If cancelled or empty, append (1) to original title
                if not new_title or vim.trim(new_title) == "" then
                    local original_title = chat_data.title or "Untitled"
                    new_title = original_title .. " (1)"
                end

                local new_save_id = self.storage:duplicate_chat(chat_data.save_id, new_title)
                if new_save_id then
                    vim.notify("Chat duplicated successfully", vim.log.levels.INFO)
                    self:open_saved_chats(filter_fn)
                else
                    vim.notify("Failed to duplicate chat", vim.log.levels.ERROR)
                end
            end)
        end,
    }, last_chat and last_chat.opts.save_id)
end

---@param save_id string
function UI:_handle_on_select(save_id)
    local maxa_ai = require("maxa")
    log:trace("Selected chat: %s", save_id)
    local chat_module = require("maxa.interactions.chat")
    local opened_chats = chat_module.buf_get_chat()
    local active_chat = chat_module.last_main_chat()
    local identity = require("maxa.session.agent_identity")

    for _, data in ipairs(opened_chats) do
        if data.chat.opts.save_id == save_id then
            local chat = data.chat
            if identity.is_main(chat) and active_chat and active_chat ~= chat and active_chat.ui:is_visible() then
                active_chat.ui:hide()
            end
            chat.ui:open({ window_opts = identity.is_subagent(chat) and {} or { layout = "vertical", position = "right" } })
            if chat.ui.winnr and api.nvim_win_is_valid(chat.ui.winnr) then api.nvim_set_current_win(chat.ui.winnr) end
            return
        end
    end

    -- Load full chat data when selecting
    local full_chat = self.storage:load_chat(save_id)
    if full_chat then
        self:create_chat(full_chat)
    else
        log:error("Failed to load chat: %s", save_id)
        vim.notify("Failed to load chat", vim.log.levels.ERROR)
    end
end

---Creates a new chat from the given chat data restoring what it can along with the adapter, settings. If adapter is not found, ask user to select another adapter. If adapter is found but model is not available, uses the adapter's default model.
---@param chat_data? MaxaAI.History.ChatData
---@return MaxaAI.History.Chat?
--- Pre-process history messages: fix incomplete tool calls, deduplicate, extract pending user content
---@param chat_data table
---@return string|nil pending_user_content
---@return table original_messages deep copy of cleaned messages
function UI:_pre_process_messages(chat_data)
    local messages = chat_data.messages
    local td = require("maxa.interactions.chat.tools.display")

    -- 1. Sanitize invalid tool_call arguments
    sanitize_tool_call_arguments(messages)

    -- 2. Find last llm message with tool_calls
    local llm_with_calls_idx = nil
    local tool_calls = nil
    for i = #messages, 1, -1 do
        local msg = messages[i]
        if msg.role == "llm" and msg.tools and msg.tools.calls and #msg.tools.calls > 0 then
            llm_with_calls_idx = i
            tool_calls = msg.tools.calls
            break
        end
    end

    -- 3. Check completeness and deduplicate
    if llm_with_calls_idx and tool_calls then
        local expected_call_ids = {}
        for _, call in ipairs(tool_calls) do
            local call_id = call.call_id or call.id
            if call_id then
                expected_call_ids[call_id] = true
            end
        end

        local found_result_ids = {}
        local duplicate_call_ids = {}
        local call_id_count = {}
        for i = llm_with_calls_idx + 1, #messages do
            local msg = messages[i]
            if msg.role == "tool" and msg.tools and msg.tools.call_id then
                local call_id = msg.tools.call_id
                found_result_ids[call_id] = true
                call_id_count[call_id] = (call_id_count[call_id] or 0) + 1
                if call_id_count[call_id] > 1 then
                    duplicate_call_ids[call_id] = true
                end
            end
        end

        -- Remove duplicate tool results (keep first)
        if next(duplicate_call_ids) then
            local seen_call_ids = {}
            for i = #messages, llm_with_calls_idx + 1, -1 do
                local msg = messages[i]
                if msg.role == "tool" and msg.tools and msg.tools.call_id then
                    local call_id = msg.tools.call_id
                    if duplicate_call_ids[call_id] then
                        if seen_call_ids[call_id] then
                            table.remove(messages, i)
                        else
                            seen_call_ids[call_id] = true
                        end
                    end
                end
            end
        end

        -- Check incomplete tool calls
        local has_incomplete_calls = false
        for call_id, _ in pairs(expected_call_ids) do
            if not found_result_ids[call_id] then
                has_incomplete_calls = true
                break
            end
        end

        if has_incomplete_calls then
            for i = #messages, llm_with_calls_idx + 1, -1 do
                if messages[i].role == "tool" then
                    table.remove(messages, i)
                end
            end
            table.remove(messages, llm_with_calls_idx)
        end
    end

    -- 4. Detect trailing user message → extract pending user content
    local pending_user_content = nil
    if not pending_user_content then
        local last_msg = messages[#messages]
        if last_msg and last_msg.role == "user"
            and not (last_msg.tools and last_msg.tools.call_id)
            and not (last_msg.opts and last_msg.opts.visible == false)
            and not (last_msg.opts and (last_msg.opts.tag or last_msg.opts.reference or last_msg.opts.context_id))
        then
            local content = last_msg.content or ""
            if vim.trim(content) ~= "" then
                pending_user_content = content
                table.remove(messages, #messages)
            end
        end
    end

    -- 6. Deep copy original messages (before modifying visibility for display)
    local original_messages = vim.deepcopy(messages)
    for i, msg in ipairs(messages) do
        msg.opts = msg.opts or {}
        -- Bind only after _post_process_chat installs the canonical list. The
        -- display copy can be deep-copied again during Chat construction.
        msg.opts._display_origin = { render_index = i }
    end
    td.rebuild_tool_summaries(messages)

    return pending_user_content, original_messages
end

--- Post-process a restored chat: replace messages, restore context, prefill edit area, etc.
---@param chat table the created Chat object
---@param chat_data table original chat_data
---@param original_messages table deep-copied original messages
---@param pending_user_content string|nil content to prefill in edit area
function UI:_post_process_chat(chat, chat_data, original_messages, pending_user_content)
    local td = require("maxa.interactions.chat.tools.display")

    -- 1. Replace messages with original (preserving API structure)
    chat.messages = original_messages
    if chat.ui and chat.ui.message_provenance then
        chat.ui.message_provenance:bind_render_indices(original_messages)
    end
    for _, msg in ipairs(chat.messages) do
        msg._meta = msg._meta or {}
    end

    -- 2. Restore context_items
    if chat_data.context_items then
        chat.context_items = {}
        for _, item in ipairs(chat_data.context_items) do
            table.insert(chat.context_items, vim.deepcopy(item))
        end
        require("maxa.session.builtin_registry").apply(chat, chat_data.schemas, chat_data.in_use)

        -- Clean buffer default context display
        local bufnr = chat.bufnr
        if bufnr and api.nvim_buf_is_valid(bufnr) then
            local lines = api.nvim_buf_get_lines(bufnr, 0, -1, false)
            local last_me_line = nil
            local user_role_name = config.interactions.chat.roles.user or "Me"
            for i = #lines, 1, -1 do
                if lines[i]:match("^## .+ ─$") then
                    local role = lines[i]:match("^## (.+) ─$")
                    if role and vim.trim(role) == user_role_name then
                        last_me_line = i
                        break
                    end
                end
            end

            if last_me_line then
                local blocks_to_delete = {}
                local ctx_start = nil
                for i = last_me_line + 1, #lines do
                    if lines[i]:match("^> Context:") then
                        ctx_start = i
                    elseif ctx_start and not lines[i]:match("^> %- <") then
                        table.insert(blocks_to_delete, { ctx_start, i - 1 })
                        ctx_start = nil
                    end
                end
                if ctx_start then
                    table.insert(blocks_to_delete, { ctx_start, #lines })
                end
                for j = #blocks_to_delete, 1, -1 do
                    local blk = blocks_to_delete[j]
            chat.ui:write_lines(blk[1] - 1, blk[2], {})
                end
            end

            -- Recalculate header_line after removing a legacy input block.
            local parser = require("maxa.interactions.chat.parser")
            local recalculated = parser.headers(chat, chat.chat_parser)
            if recalculated then
                chat.header_line = recalculated + 1
            end
        end
    end

    -- 3. Prefill edit area
    if pending_user_content and pending_user_content ~= "" then
        local bufnr = chat.bufnr
        if bufnr and api.nvim_buf_is_valid(bufnr) then
            chat.ui:unlock_buf()
            local total = api.nvim_buf_line_count(bufnr)
            local trim_end = total
            while trim_end > 1 do
                local line = api.nvim_buf_get_lines(bufnr, trim_end - 1, trim_end, false)[1]
                if line and vim.trim(line) == "" then
                    trim_end = trim_end - 1
                else
                    break
                end
            end
            if trim_end < total then
                chat.ui:write_lines(trim_end + 1, total, {})
            end
            local content_lines = vim.split(pending_user_content, "\n", { plain = true })
            chat.ui:write_lines(-1, -1, content_lines)
            chat.cycle = (chat.cycle or 1) + 1
            local last_line = api.nvim_buf_line_count(bufnr)
            local last_col = #(api.nvim_buf_get_lines(bufnr, last_line - 1, last_line, false)[1] or "")
            local win = vim.fn.bufwinid(bufnr)
            if win ~= -1 then
                pcall(api.nvim_win_set_cursor, win, { last_line, last_col })
            end
        end
    end

    -- 5. Restore Ability hooks
    local sh_ok, ability_hooks = pcall(require, "maxa.abilities.hooks")
    if sh_ok and ability_hooks.restore_hooks_from_messages then
        ability_hooks.restore_hooks_from_messages(chat)
    end

    -- Shared presentation postprocess uses logical provenance, not matching text.
    td.apply_render_postprocess(chat, chat_data.messages)

end

function UI:create_chat(chat_data, display_opts)
    log:trace("Creating new chat from saved data")
    chat_data = chat_data or {}
    display_opts = display_opts or {}
    local messages = chat_data.messages or {}
    local save_id = chat_data.save_id
    local title = chat_data.title

    -- Pre-process messages if there are any (fix incomplete calls, extract pending, build summaries)
    local pending_user_content, original_messages
    if messages and vim.tbl_count(messages) > 0 then
        pending_user_content, original_messages = self:_pre_process_messages(chat_data)
        messages = chat_data.messages -- may have been modified
    end

    local chat_module = require("maxa.interactions.chat")
    local function display_content(value)
        if type(value) == "string" then
            return value
        end
        if type(value) == "table" then
            if type(value.content) == "string" then
                return value.content
            end
            local ok, encoded = pcall(vim.json.encode, value)
            if ok and type(encoded) == "string" then
                return encoded
            end
        end
        if value == nil then
            return nil
        end
        return tostring(value)
    end

    -- Provider reasoning metadata is retained for API replay, never serialized
    -- into visible text when no readable reasoning content is available.
    local function reasoning_text(value)
        if type(value) == "string" then
            return value
        end
        if type(value) == "table" and type(value.content) == "string" then
            return value.content
        end
    end

    local function build_render_messages(source_messages)
        local render_messages = {}
        local in_reasoning = false
        for _, msg in ipairs(source_messages or {}) do
            local render_msg = vim.deepcopy(msg)
            render_msg.opts = render_msg.opts or {}
            render_msg.opts._display_origin = msg.opts and msg.opts._display_origin
            if render_msg.role == config.constants.USER_ROLE and render_msg.opts.visible ~= false then
                in_reasoning = false
            end
            local reasoning_content = render_msg.role == config.constants.LLM_ROLE and reasoning_text(render_msg.reasoning) or nil
            if reasoning_content and reasoning_content ~= "" then
                in_reasoning = true
                table.insert(render_messages, {
                    role = config.constants.LLM_ROLE,
                    content = "### Reasoning\n\n" .. reasoning_content,
                    opts = {
                        type = chat_module.MESSAGE_TYPES.REASONING_MESSAGE,
                        visible = true,
                        _display_origin = msg.opts and msg.opts._display_origin,
                    },
                    _meta = vim.deepcopy(render_msg._meta or {}),
                })
            end

            render_msg.content = display_content(render_msg.content) or ""
            if in_reasoning and render_msg.opts.visible ~= false and render_msg.content ~= ""
                and render_msg.role ~= config.constants.SYSTEM_ROLE and render_msg.role ~= config.constants.USER_ROLE then
                in_reasoning = false
                render_msg.content = "### Response\n\n" .. render_msg.content
                -- Tool result spans are relative to the unprefixed message body.
                for _, span in ipairs(render_msg.opts._display_spans or {}) do
                    span[1] = span[1] + 2
                    span[2] = span[2] + 2
                end
            end
            table.insert(render_messages, render_msg)
        end
        return render_messages
    end

    local function apply_history_reasoning_folds(chat)
        if not (chat and chat.bufnr and chat.ui and chat.ui.folds and config.display.chat.fold_reasoning) then
            return
        end

        local bufnr = chat.bufnr
        if not api.nvim_buf_is_valid(bufnr) then
            return
        end

        local lines = api.nvim_buf_get_lines(bufnr, 0, -1, false)
        if vim.tbl_isempty(lines) then
            return
        end

        local folds = chat.ui.folds
        local summary_text = "  " .. (config.display.chat.icons.chat_fold or "") .. " ..."
        local function create_reasoning_fold(start_row, end_row)
            if end_row <= start_row then
                return
            end

            -- Use MaxaAI's fold registry path so fold_text() can resolve the
            -- reasoning summary. A plain `:fold` creates a visual fold but leaves
            -- Folds.fold_summaries empty, which renders as "Unknown" after restore.
            if folds.recreate then
                folds:recreate(bufnr, start_row, end_row, {
                    type = "reasoning",
                    content = summary_text,
                })
                return
            end

            -- Defensive fallback for older MaxaAI versions.
            folds.fold_summaries = folds.fold_summaries or {}
            folds.fold_summaries[bufnr] = folds.fold_summaries[bufnr] or {}
            folds.fold_summaries[bufnr][start_row] = {
                type = "reasoning",
                content = summary_text,
            }
            pcall(vim.cmd, string.format("%d,%dfold", start_row + 1, end_row + 1))
        end

        local function apply()
            local seen = {}
            for line_idx, line in ipairs(lines) do
                if line == "### Reasoning" then
                    -- line_idx is 1-based and points at the heading. MaxaAI
                    -- folds reasoning content starting on the line after the heading,
                    -- represented as 0-based start_row = line_idx.
                    local fold_start = line_idx
                    local fold_end_lnum = #lines
                    for j = line_idx + 1, #lines do
                        if lines[j] == "### Reasoning" or lines[j] == "### Response" or lines[j]:match("^## .+ ─$") then
                            fold_end_lnum = j - 1
                            break
                        end
                    end
                    local fold_end = fold_end_lnum - 1
                    if fold_end >= fold_start and not seen[fold_start] then
                        seen[fold_start] = true
                        create_reasoning_fold(fold_start, fold_end)
                    end
                end
            end
        end

        local win = vim.fn.bufwinid(bufnr)
        if win ~= -1 then
            api.nvim_win_call(win, apply)
        else
            api.nvim_buf_call(bufnr, apply)
        end
    end

    local function restore_history_input_cursor(chat)
        if not (chat and chat.bufnr and chat.ui and api.nvim_buf_is_valid(chat.bufnr)) then
            return
        end

        local ui = chat.ui
        if ui.cursor then
            ui.cursor.has_moved = false
            ui.cursor.pos = nil
        end

        if ui.follow then
            pcall(function()
                ui:follow()
            end)
        end

        -- Force one final cursor placement after history post-processing. Restore
        -- cleanup can delete context lines and create folds after UI:render() has
        -- already followed the buffer, leaving the normal-mode cursor several lines
        -- away from the real edit area until InsertEnter refreshes it.
        local win = ui.winnr or vim.fn.bufwinid(chat.bufnr)
        if win and win ~= -1 and api.nvim_win_is_valid(win) and ui.last then
            local last_line, last_column, line_count = ui:last()
            if line_count and line_count > 0 then
                pcall(api.nvim_win_set_cursor, win, { last_line + 1, last_column })
            end
        end
    end

    local last_msg = messages[#messages]

    --HACK: Ensure last message is from user to show header
    if
        last_msg and (last_msg.role ~= "user" or (last_msg.role == "user" and (last_msg.opts or {}).visible == false))
    then
        log:trace("Adding empty user message to ensure header visibility")
        table.insert(messages, {
            role = "user",
            content = "",
            opts = { visible = true, force_role = last_msg and last_msg.opts and last_msg.opts._presentation_display == true },
        })
    end

    local render_messages = build_render_messages(messages)
    local context_utils = require("maxa.utils.context")
    local last_active_buffer = require("maxa.session.history.utils").get_editor_info().last_active
    local context = context_utils.get(last_active_buffer and last_active_buffer.bufnr or nil)
    ---@param adapter string?
    ---@param settings table?
    local function _create_chat(adapter, settings)
    chat_data._history_restored = true
    local chat = chat_module.new({
            save_id = save_id,
            messages = render_messages,
            buffer_context = context,
            cwd = chat_data.cwd or context.cwd,
            project_root = chat_data.project_root or context.project_root,
            settings = settings,
            adapter = adapter --[[@as MaxaAI.Adapter]],
            title = title,
            _meta = chat_data._meta,
            history_updated_at = chat_data.updated_at,
            window_opts = display_opts.window_opts or { layout = "vertical", position = "right" },
            preserve_main = display_opts.preserve_main,
            _history_restored = true,
            compact_protected_prefix_count = chat_data.compact_protected_prefix_count
                or (chat_data.opts and chat_data.opts.compact_protected_prefix_count)
                or 0,
        }) --[[@as MaxaAI.History.Chat]]
        chat._compact_protected_prefix_count = chat_data.compact_protected_prefix_count
            or (chat_data.opts and chat_data.opts.compact_protected_prefix_count)
            or 0
        chat.opts.compact_protected_prefix_count = chat._compact_protected_prefix_count
        local stored_context_items = chat_data.context_items or {}
        local chat_context_items = chat.context_items or {}
        for _, item in ipairs(stored_context_items) do
            local is_duplicate = vim.tbl_contains(chat_context_items, function(chat_item)
                return chat_item.id == item.id
            end, { predicate = true })
            if not is_duplicate then
                chat.context:add(item)
            end
        end
        require("maxa.session.builtin_registry").apply(chat, chat_data.schemas, chat_data.in_use)
        chat.cycle = chat_data.cycle or 1
        chat.opts.title_refresh_count = chat_data.title_refresh_count or 0
        chat._meta.notify_when_done = nil

        -- Post-process: restore original messages, context, prefill, highlights
        if original_messages then
            self:_post_process_chat(chat, chat_data, original_messages, pending_user_content)
            chat._compact_protected_prefix_count = chat_data.compact_protected_prefix_count
                or (chat_data.opts and chat_data.opts.compact_protected_prefix_count)
                or 0
            chat.opts.compact_protected_prefix_count = chat._compact_protected_prefix_count
            vim.schedule(function()
                apply_history_reasoning_folds(chat)
                restore_history_input_cursor(chat)
                vim.schedule(function()
                    restore_history_input_cursor(chat)
                end)
            end)
        end

        -- Reconnect only provenance-valid persisted MCP authorizations. This does
        -- not replay load/call history or append duplicate context.
        vim.schedule(function()
            require("maxa.session.abilities").rehydrate(chat)
        end)

        log:trace("Successfully created chat with save_id: %s", save_id or "N/A")
        return chat
    end
    local adapter = chat_data.adapter
    local settings = chat_data.settings or {}
    if adapter then
        local found, resolved_adapter = pcall(require("maxa.adapters").resolve, adapter)
        -- If the adapter is not found, we need to change it. If found, we need to check if the model is available
        if not found then
            vim.notify(
                string.format(
                    "History chat adapter '%s' is not available. Falling back to the default adapter/model.",
                    adapter
                ),
                vim.log.levels.WARN
            )
            return _create_chat(nil, nil)
        else
            local saved_model = settings.model
            if saved_model then
                local available_models = resolved_adapter.schema.model.choices
                --INFO:Skipping if models is a function
                -- if type(available_models) == "function" then
                --     vim.notify("Please wait while we fetch the avaiable models in " .. adapter)
                --     available_models = available_models(resolved_adapter)
                -- end
                if type(available_models) == "table" then
                    available_models = vim.iter(available_models)
                        :map(function(model, value)
                            if type(model) == "string" then
                                return model
                            else
                                return value -- This is for the table entry case
                            end
                        end)
                        :totable()
                    local has_model = vim.tbl_contains(available_models, saved_model)
                    if not has_model then
                        vim.notify(
                            string.format(
                                "History chat model '%s' is not available in '%s' adapter. Falling back to the default adapter/model.",
                                saved_model,
                                adapter
                            ),
                            vim.log.levels.WARN
                        )
                        return _create_chat(nil, nil)
                        --INFO: this results in rare errors where the model opts differ from one model to another model.
                        -- return self:_change_model(available_models, function(model)
                        --     settings.model = model
                        --     create_chat(adapter, nil)
                        -- end)
                    end
                end
            end
        end
    end
    return _create_chat(adapter, settings)
end

---[[Most of the code is copied from maxa_ai/interactions/chat/ui.lua]]
---Retrieve the lines to be displayed in the preview window
---@param chat_data MaxaAI.History.ChatData
function UI:_get_preview_lines(chat_data)
    local lines = {}
    local function spacer()
        table.insert(lines, "")
    end
    local function set_header(tbl, role)
        local header = "## " .. role
        table.insert(tbl, header)
        table.insert(tbl, "")
    end
    local system_role = config.constants.SYSTEM_ROLE
    local user_role = config.constants.USER_ROLE
    local assistant_role = config.constants.LLM_ROLE
    local last_role
    local last_set_role
    local function add_messages_to_buf(msgs)
        for i, msg in ipairs(msgs) do
            if (msg.role ~= system_role) and not (msg.opts and msg.opts.visible == false) then
                -- Keep the main user role adjacent to preceding prompt-library history.
                if i > 1 and last_role ~= msg.role and msg.role ~= user_role then
                    spacer()
                end

                if msg.role == user_role and last_set_role ~= user_role then
                    if last_set_role ~= nil then
                        spacer()
                    end
                    set_header(lines, "  User")
                end
                if msg.role == assistant_role and last_set_role ~= assistant_role then
                    set_header(lines, "  Assistant")
                end

                if msg.opts and msg.opts.tag == "tool_output" then
                    table.insert(lines, "### Tool Output")
                    table.insert(lines, "")
                end

                local trimempty = not (msg.role == "user" and msg.content == "")
                local display_content = msg.content or ""
                --INFO: For anthropic adapter, the tool output is in content.content
                if type(display_content) == "table" then
                    if type(msg.content.content) == "string" then
                        display_content = msg.content.content
                    else
                        display_content = "[Message Cannot Be Displayed]"
                    end
                end
                for _, text in ipairs(vim.split(display_content or "", "\n", { plain = true, trimempty = trimempty })) do
                    table.insert(lines, text)
                end

                last_set_role = msg.role
                last_role = msg.role

                -- The Chat:Submit method will parse the last message and it to the messages table
                if i == #msgs then
                    table.remove(msgs, i)
                end
            end
        end
    end

    if chat_data.settings then
        lines = { "---" }
        table.insert(lines, string.format("adapter: %s", vim.inspect(chat_data.adapter)))
        table.insert(lines, string.format("model: %s", vim.inspect(chat_data.settings.model)))
        -- Sort keys alphabetically
        local sorted_keys = {}
        for key in pairs(chat_data.settings) do
            table.insert(sorted_keys, key)
        end
        table.sort(sorted_keys)
        for _, key in ipairs(sorted_keys) do
            if key ~= "model" then
                table.insert(lines, string.format("%s: %s", key, vim.inspect(chat_data.settings[key])))
            end
        end
        table.insert(lines, "---")
        spacer()
    end
    if vim.tbl_isempty(chat_data.messages) then
        set_header(lines, user_role)
        spacer()
    else
        add_messages_to_buf(chat_data.messages)
    end
    return lines
end

---@param chat MaxaAI.History.Chat
---@param saved_at number
function UI:update_last_saved(chat, saved_at)
    log:trace("Updating last saved time for chat: %s", chat.opts.save_id or "N/A")
    --saved at icon
    local icon = " "
    self:update_chat_title(chat, icon .. utils.format_time(saved_at))
end

local function select_opts(prompt, conditional)
    return {
        prompt = prompt,
        kind = "maxa_ai",
        format_item = function(item)
            if conditional == item then
                return "* " .. item
            end
            return "  " .. item
        end,
    }
end

---@param on_select fun(adapter: string, settings: table?):nil
function UI:_change_adapter(on_select)
    local adapters = vim.deepcopy(config.adapters)

    local adapters_list = vim.iter(adapters)
        :filter(function(adapter)
            return adapter ~= "opts" and adapter ~= "non_llms"
        end)
        :map(function(adapter, _)
            return adapter
        end)
        :totable()
    table.sort(adapters_list)
    -- table.insert(adapters_list, 1, current_adapter)
    vim.ui.select(adapters_list, select_opts("Select Adapter"), function(selected)
        if not selected then
            return
        end
        local found, adapter = pcall(require("maxa.adapters").resolve, selected)
        if found and adapter then
            --set chat settings to nil, so that old adapter's settings are not used
            on_select(selected, nil)
        end
    end)
end

---@param available_models string[]
---@param on_select fun(model: string):nil
function UI:_change_model(available_models, on_select)
    local models = vim.deepcopy(available_models)
    table.sort(models)
    vim.ui.select(models, select_opts("Select Model"), function(selected)
        if not selected then
            return
        end
        on_select(selected)
    end)
end

return UI
