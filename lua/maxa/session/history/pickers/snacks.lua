---@class MaxaAI.History.SnacksPicker : MaxaAI.History.DefaultPicker
local SnacksPicker = setmetatable({}, {
    __index = require("maxa.session.history.pickers.default"),
})
SnacksPicker.__index = SnacksPicker

function SnacksPicker:browse()
    vim.api.nvim_set_hl(0, "MaxaHistoryRunning", { default = true, link = "DiagnosticOk" })
    vim.api.nvim_set_hl(0, "MaxaHistoryOpen", { default = true, link = "DiagnosticInfo" })
    local keymaps = vim.tbl_deep_extend("force", {
        rename = { n = "r", i = "<M-r>" },
        delete = { n = "d", i = "<M-d>" },
        duplicate = { n = "<C-y>", i = "<C-y>" },
        stats = { n = "s", i = "<M-s>" },
        copy_to_project = { n = "Y", i = "<M-y>" },
        move_to_project = { n = "M", i = "<M-m>" },
    }, self.config.keymaps or {})

    local identity = require("maxa.session.agent_identity")
    local tree = self.config.tree or identity.tree(self.config.items)
    local tree_mode, query, collapsed = true, "", {}
    local function refresh(picker, selected_id)
        picker:find({ refresh = true, on_done = function()
            for i, item in ipairs(picker.list.items) do
                if item.save_id == selected_id then picker.list:view(i); break end
            end
        end })
    end
    local function fold_all(picker, collapse)
        local item = picker:current()
        local node = item and tree.by_id[item.save_id]
        collapsed = {}
        if collapse then
            for id, entry in pairs(tree.by_id) do
                if #entry.children > 0 then collapsed[id] = true end
            end
            while node and node.parent do node = node.parent end
        end
        tree_mode, query = true, ""
        picker.opts.title = self.config.title .. " — Tree (Ctrl+L: flat)"
        picker.input:set("", "")
        refresh(picker, node and node.id or (item and item.save_id))
    end
    local function rows()
        if not tree_mode then return vim.deepcopy(self.config.flat_items or self.config.items) end
        local keep
        if query ~= "" then
            keep = {}
            local matcher = require("snacks.picker.core.matcher").new({ file_pos = false, filename_bonus = false })
            matcher:init(query)
            for _, node in pairs(tree.by_id) do
                if matcher:match({ text = self:get_item_title(node.item) }) > 0 then
                    keep[node.id] = true
                    for _, parent in ipairs(identity.ancestors(node)) do keep[parent.id] = true end
                end
            end
        end
        local result = {}
        local function append(nodes, depth, guides)
            local visible = {}
            for _, node in ipairs(nodes) do
                if not keep or keep[node.id] then visible[#visible + 1] = node end
            end
            for i, node in ipairs(visible) do
                local last = i == #visible
                result[#result + 1] = vim.tbl_extend("force", {}, node.item, {
                    tree_depth = depth, tree_children = #node.children, tree_collapsed = not keep and collapsed[node.id] or nil,
                    tree_prefix = depth == 0 and "" or (guides .. (last and "└─" or "├─")),
                })
                if keep or not collapsed[node.id] then
                    append(node.children, depth + 1, depth == 0 and "" or (guides .. (last and "   " or "│  ")))
                end
            end
        end
        append(tree.roots, 0, "")
        return result
    end
    require("snacks.picker").pick({
        title = self.config.title .. " — Tree (Ctrl+L: flat)",
        finder = rows,
        sort = { fields = { "idx" } },
        filter = { transform = function(_, filter)
            local changed = query ~= filter.pattern
            query = filter.pattern
            if tree_mode then filter.pattern = "" end
            return changed
        end },
        main = { file = false, float = true },
        format = function(item)
            return self:format_entry_parts(item)
        end,
        transform = function(item)
            item.file = self:get_item_id(item)
            item.text = self:get_item_title(item)
            return item
        end,
        preview = function(ctx)
            local item = ctx.item
            local lines = self.config.handlers.on_preview(item)
            if not lines then
                return
            end

            local buf_id = ctx.preview:scratch()
            vim.bo[buf_id].filetype = "markdown"
            vim.api.nvim_buf_set_lines(buf_id, 0, -1, false, lines)
        end,
        confirm = function(picker, _)
            local items = picker:selected({ fallback = true })
            if items then
                picker:close()
                vim.iter(items):each(function(item)
                    self.config.handlers.on_select(item)
                end)
            end
        end,
        actions = {
            tree_collapse_all = function(picker) fold_all(picker, true) end,
            tree_expand_all = function(picker) fold_all(picker, false) end,
            toggle_tree = function(picker)
                local item = picker:current()
                tree_mode = not tree_mode
                picker.opts.title = self.config.title .. (tree_mode and " — Tree (Ctrl+L: flat)" or " — Flat (Ctrl+L: tree)")
                refresh(picker, item and item.save_id)
            end,
            tree_left = function(picker)
                if not tree_mode then return end
                local item = picker:current()
                local node = item and tree.by_id[item.save_id]
                if not node then return end
                if #node.children > 0 and not collapsed[node.id] then
                    collapsed[node.id] = true
                    refresh(picker, node.id)
                elseif node.parent then
                    for i, row in ipairs(picker.list.items) do
                        if row.save_id == node.parent.id then picker.list:view(i); break end
                    end
                end
            end,
            tree_right = function(picker)
                if not tree_mode then return end
                local item = picker:current()
                local node = item and tree.by_id[item.save_id]
                if not node or #node.children == 0 then return end
                if collapsed[node.id] then collapsed[node.id] = nil; refresh(picker, node.id)
                else refresh(picker, node.children[1].id) end
            end,
            rename_item = function(picker)
                local selections = picker:selected({ fallback = true })
                if #selections ~= 1 then
                    return vim.notify(
                        "Can rename only one " .. self:get_item_name_singular() .. " at a time",
                        vim.log.levels.WARN
                    )
                end
                local selection = selections[1]
                picker:close()
                self.config.handlers.on_rename(selection)
            end,
            delete_item = function(picker)
                local selections = picker:selected({ fallback = true })
                if #selections == 0 then
                    return
                end
                picker:close()
                self.config.handlers.on_delete(selections)
            end,
            duplicate_chat = function(picker)
                local selections = picker:selected({ fallback = true })
                if #selections ~= 1 then
                    return vim.notify("Can duplicate only one chat at a time", vim.log.levels.WARN)
                end
                local selection = selections[1]
                picker:close()
                self.config.handlers.on_duplicate(selection)
            end,
            copy_to_project = function(picker)
                local selections = picker:selected({ fallback = true })
                if #selections ~= 1 then
                    return vim.notify("Can copy only one chat at a time", vim.log.levels.WARN)
                end
                local selection = selections[1]
                picker:close()
                if type(self.config.handlers.on_copy_to_project) == "function" then
                    self.config.handlers.on_copy_to_project(selection)
                end
            end,
            move_to_project = function(picker)
                local selections = picker:selected({ fallback = true })
                if #selections ~= 1 then
                    return vim.notify("Can move only one chat at a time", vim.log.levels.WARN)
                end
                local selection = selections[1]
                picker:close()
                if type(self.config.handlers.on_move_to_project) == "function" then
                    self.config.handlers.on_move_to_project(selection)
                end
            end,
            show_session_stats = function(picker)
                local selections = picker:selected({ fallback = true })
                if #selections ~= 1 then
                    return vim.notify("Can inspect only one chat at a time", vim.log.levels.WARN)
                end
                local selection = selections[1]
                picker:close()
                if type(self.config.handlers.on_stats) == "function" then
                    self.config.handlers.on_stats(selection)
                end
            end,
        },

        win = {
            input = {
                keys = {
                    ["<C-l>"] = { "toggle_tree", mode = { "n", "i" } },
                    ["h"] = { "tree_left", mode = "n" },
                    ["l"] = { "tree_right", mode = "n" },
                    ["H"] = { "tree_collapse_all", mode = "n" },
                    ["L"] = { "tree_expand_all", mode = "n" },
                    [keymaps.delete.n] = { "delete_item", mode = "n" },
                    [keymaps.delete.i] = { "delete_item", mode = "i" },
                    [keymaps.rename.n] = { "rename_item", mode = "n" },
                    [keymaps.rename.i] = { "rename_item", mode = "i" },
                    [keymaps.duplicate.n] = { "duplicate_chat", mode = "n" },
                    [keymaps.duplicate.i] = { "duplicate_chat", mode = "i" },
                    [keymaps.stats.n] = { "show_session_stats", mode = "n" },
                    [keymaps.stats.i] = { "show_session_stats", mode = "i" },
                    [keymaps.copy_to_project.n] = { "copy_to_project", mode = "n" },
                    [keymaps.copy_to_project.i] = { "copy_to_project", mode = "i" },
                    [keymaps.move_to_project.n] = { "move_to_project", mode = "n" },
                    [keymaps.move_to_project.i] = { "move_to_project", mode = "i" },
                },
            },
            list = {
                keys = {
                    ["<C-l>"] = { "toggle_tree", mode = { "n", "i" } },
                    ["h"] = { "tree_left", mode = "n" },
                    ["l"] = { "tree_right", mode = "n" },
                    ["H"] = { "tree_collapse_all", mode = "n" },
                    ["L"] = { "tree_expand_all", mode = "n" },
                    [keymaps.delete.n] = { "delete_item", mode = "n" },
                    [keymaps.delete.i] = { "delete_item", mode = "i" },
                    [keymaps.rename.n] = { "rename_item", mode = "n" },
                    [keymaps.rename.i] = { "rename_item", mode = "i" },
                    [keymaps.duplicate.n] = { "duplicate_chat", mode = "n" },
                    [keymaps.duplicate.i] = { "duplicate_chat", mode = "i" },
                    [keymaps.stats.n] = { "show_session_stats", mode = "n" },
                    [keymaps.stats.i] = { "show_session_stats", mode = "i" },
                    [keymaps.copy_to_project.n] = { "copy_to_project", mode = "n" },
                    [keymaps.copy_to_project.i] = { "copy_to_project", mode = "i" },
                    [keymaps.move_to_project.n] = { "move_to_project", mode = "n" },
                    [keymaps.move_to_project.i] = { "move_to_project", mode = "i" },
                },
            },
        },
    })
end

return SnacksPicker
