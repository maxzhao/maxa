---@diagnostic disable: param-type-mismatch
--[[ Adapted from nui.text by Munif Tanjim
Source: https://github.com/MunifTanjim/nui.nvim/blob/main/lua/nui/text/init.lua
License: MIT ]]
local Object = {}
Object.__index = Object

---@class nui_text_extmark
---@field id? integer
---@field hl_group? string
---@field [string] any

local Text = Object

---@param content string|table text content or NuiText object
---@param extmark? string|nui_text_extmark highlight group name or extmark options
function Text:init(content, extmark)
    if type(content) == "string" then
        self:set(content, extmark)
    else
        -- cloning
        self:set(content._content, extmark or content.extmark)
    end
end

---@param content string text content
---@param extmark? string|nui_text_extmark highlight group name or extmark options
---@return table
function Text:set(content, extmark)
    if self._content ~= content then
        self._content = content
        self._length = vim.fn.strlen(content)
        self._width = vim.api.nvim_strwidth(content)
    end

    if extmark then
        -- preserve self.extmark.id
        local id = self.extmark and self.extmark.id or nil
        self.extmark = type(extmark) == "string" and {
            hl_group = extmark,
        } or vim.deepcopy(extmark)
        self.extmark.id = id
    end

    return self
end

---@return string
function Text:content()
    return self._content
end

---@return number
function Text:length()
    return self._length
end

---@return number
function Text:width()
    return self._width
end

---@param bufnr number buffer number
---@param ns_id number namespace id
---@param linenr number line number (1-indexed)
---@param start_col number start byte position (0-indexed)
function Text:highlight(bufnr, ns_id, linenr, start_col)
    if not self.extmark then
        return
    end

    start_col = start_col or 0
    self.extmark.end_col = start_col + self:length()

    self.extmark.id = vim.api.nvim_buf_set_extmark(bufnr, ns_id, linenr - 1, start_col, self.extmark)
end

---@param bufnr number buffer number
---@param ns_id number namespace id
---@param linenr_start number start line number (1-indexed)
---@param byte_start number start byte position (0-indexed)
---@param linenr_end? number end line number (1-indexed)
---@param byte_end? number end byte position (0-indexed)
function Text:render(bufnr, ns_id, linenr_start, byte_start, linenr_end, byte_end)
    local row_start = linenr_start - 1
    local row_end = linenr_end and linenr_end - 1 or row_start

    -- Start at column 0 if byte_start is nil
    local col_start = byte_start or 0
    -- If byte_end is nil, set it based on col_start and text length
    local col_end = byte_end or col_start + self:length()

    local content = self:content()

    -- Clear existing content first
    vim.api.nvim_buf_set_text(bufnr, row_start, col_start, row_end, col_start, { "" })
    -- Insert new content
    vim.api.nvim_buf_set_text(bufnr, row_start, col_start, row_start, col_start, { content })

    -- Highlight from col_start
    self:highlight(bufnr, ns_id, linenr_start, col_start)
end

-- Constructor
local NuiText = setmetatable({}, {
    __call = function(cls, content, extmark)
        local instance = setmetatable({}, Object)
        instance:init(content, extmark)
        return instance
    end,
})

return NuiText
