local utils = require("maxa.session.history.utils")

---@class MaxaAI.History.PickerConfig
---@field items MaxaAI.History.EntryItem[] Array of items to display
---@field handlers MaxaAI.History.UIHandlers Action handlers
---@field keymaps table Picker keymaps
---@field current_item_id? string Current item ID for highlighting
---@field title string Picker title

---@class MaxaAI.History.DefaultPicker
---@field config MaxaAI.History.PickerConfig
local DefaultPicker = {}
DefaultPicker.__index = DefaultPicker

---@param config MaxaAI.History.PickerConfig
---@return MaxaAI.History.DefaultPicker
function DefaultPicker:new(config)
    local base = setmetatable({}, self)
    self.config = config
    return base
end

function DefaultPicker:browse()
    vim.ui.select(self.config.items, {
        prompt = self.config.title,
        format_item = function(item)
            return self:format_entry(item)
        end,
    }, function(selected)
        if selected then
            self.config.handlers.on_select(selected)
        end
    end)
end

---Get the unique ID for an item
---@param item table
---@return string
function DefaultPicker:get_item_id(item)
    return item.save_id
end

---Get the display title for an item
---@param item table
---@return string
function DefaultPicker:get_item_title(item)
    return item.title or "Untitled"
end

---Check if an item is the current item
---@param item table
---@return boolean
function DefaultPicker:is_current_item(item)
    return self.config.current_item_id == self:get_item_id(item)
end

---Get the item name for user messages (singular)
---@return string
function DefaultPicker:get_item_name_singular()
    return "chat"
end

---Get the item name for user messages (plural)
---@return string
function DefaultPicker:get_item_name_plural()
    return "chats"
end

---Format entry for display
---@param entry MaxaAI.History.EntryItem Entry from the index
---@return string formatted_display
function DefaultPicker:format_entry(entry)
    return self:_format_chat_entry(entry)
end

---Format a chat entry for display
---@param entry MaxaAI.History.EntryItem Entry from the index
---@return string formatted_display
function DefaultPicker:_format_chat_entry(entry)
    local text = {}
    for _, part in ipairs(self:format_entry_parts(entry)) do
        text[#text + 1] = part[1]
    end
    return table.concat(text)
end

---Format text segments; plain-text pickers keep using format_entry.
---@param entry MaxaAI.History.EntryItem
---@return table[]
function DefaultPicker:format_entry_parts(entry)
    local parts = {}
    local function append(text, hl)
        if #parts > 0 then parts[#parts + 1] = { " " } end
        parts[#parts + 1] = { text, hl }
    end

    -- Current chat indicator remains independent of its running state.
    append(self:is_current_item(entry) and "" or " ")

    -- Snacks supplies visible file-tree branches, with no prefix on roots.
    if entry.tree_prefix ~= nil then
        if entry.tree_prefix ~= "" then append(entry.tree_prefix) end
    elseif entry.tree_depth and entry.tree_depth > 0 then
        local marker = (entry.tree_children or 0) > 0 and (entry.tree_collapsed and "▸ " or "▾ ") or "  "
        append(string.rep("  ", entry.tree_depth) .. marker)
    end
    if entry.tree_prefix == nil and require("maxa.session.agent_identity").history(entry).kind == "subagent" then
        append("[child]")
    end
    append(self:get_item_title(entry), entry.title_hl)
    if entry.tree_collapsed and (entry.tree_children or 0) > 0 then
        append("[+]", "Comment")
    end

    if entry.token_estimate then
        append(string.format("(~%.1fk)", entry.token_estimate / 1000))
    end

    append(" " .. utils.format_relative_time(entry.tree_depth and (entry.last_dialogue_at or entry.updated_at) or entry.updated_at))
    return parts
end

return DefaultPicker
