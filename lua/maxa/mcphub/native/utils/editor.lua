local M = {}

---@class BufferInfo
---@field name string
---@field filename string
---@field windows number[]
---@field winnr number
---@field cursor_pos number[]
---@field filetype string
---@field line_count number
---@field is_visible boolean
---@field is_modified boolean
---@field is_loaded boolean
---@field lastused number
---@field bufnr number

---@class EditorInfo
---@field last_active BufferInfo?
---@field buffers BufferInfo[]

---@return EditorInfo
function M.get_editor_info()
    local buffers = vim.fn.getbufinfo({ buflisted = 1 })
    local valid_buffers = {}
    local last_active = nil
    local max_lastused = 0

    for _, buf in ipairs(buffers) do
        local buftype = vim.api.nvim_get_option_value("buftype", { buf = buf.bufnr })
        if buf.name ~= "" and buftype == "" then
            local buffer_info = {
                bufnr = buf.bufnr,
                name = buf.name,
                filename = buf.name,
                is_visible = #buf.windows > 0,
                is_modified = buf.changed == 1,
                is_loaded = buf.loaded == 1,
                lastused = buf.lastused,
                windows = buf.windows,
                winnr = buf.windows[1],
            }

            if buffer_info.is_visible then
                buffer_info.cursor_pos = vim.api.nvim_win_get_cursor(buffer_info.winnr)
            end

            buffer_info.filetype = vim.api.nvim_get_option_value("filetype", { buf = buf.bufnr })
            buffer_info.line_count = vim.api.nvim_buf_line_count(buf.bufnr)
            table.insert(valid_buffers, buffer_info)

            if buf.lastused > max_lastused then
                max_lastused = buf.lastused
                last_active = buffer_info
            end
        end
    end

    if not last_active and #valid_buffers > 0 then
        last_active = valid_buffers[1]
    end

    return {
        last_active = last_active,
        buffers = valid_buffers,
    }
end

return M
