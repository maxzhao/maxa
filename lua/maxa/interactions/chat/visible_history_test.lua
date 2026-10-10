-- Run: nvim --headless -u NONE -l lua/maxa/interactions/chat/visible_history_test.lua
vim.opt.runtimepath:prepend(vim.fn.stdpath("data") .. "/lazy/plenary.nvim")
vim.opt.runtimepath:prepend(vim.fn.getcwd())

local api = vim.api
local Chat = require("maxa.interactions.chat")
local config = require("maxa.config")

local bufnr = api.nvim_create_buf(false, true)
api.nvim_set_current_buf(bufnr)
api.nvim_buf_set_lines(bufnr, 0, -1, false, { "## Me", "", "  draft after slash  ", "", "tail  ", "" })
vim.bo[bufnr].filetype = "markdown"
local parser = vim.treesitter.get_parser(bufnr, "markdown")

local rendered
local ui = {
  winnr = 0,
  render = function(self, _, messages)
    rendered = vim.deepcopy(messages)
    local lines = {}
    for _, message in ipairs(messages) do
      local role = message.role == "user" and "Me" or "MaxaAI (Test)"
      vim.list_extend(lines, { "## " .. role, "" })
      vim.list_extend(lines, vim.split(message.content or "", "\n", { plain = true, trimempty = false }))
    end
    api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    return self
  end,
  is_active = function() return false end,
  unlock_buf = function() vim.bo[bufnr].modifiable = true end,
  lock_buf = function() vim.bo[bufnr].modifiable = false end,
}

local chat = {
  bufnr = bufnr,
  messages = {},
  cycle = 1,
  header_line = 1,
  _last_role = config.constants.USER_ROLE,
  chat_parser = parser,
  buffer_context = {},
  ui = ui,
  context = { clear_rendered = function() end, render = function() end },
  tools = { messages = nil },
}
chat.capture_editable_draft = Chat.capture_editable_draft
chat.add_message = function(self, data, opts)
  table.insert(self.messages, {
    role = data.role,
    content = data.content,
    opts = opts,
    _meta = opts and opts._meta,
  })
  return self
end

local display_name = "maxa.interactions.chat.tools.display"
local original_display = package.loaded[display_name]
package.loaded[display_name] = {
  build_render_messages = function(messages) return vim.deepcopy(messages) end,
  apply_render_postprocess = function() end,
}

local ok, err = Chat.add_visible_history(chat, {
  { role = "user", content = "Follow these requirements." },
  { role = "llm", content = "I will follow them." },
}, nil)
package.loaded[display_name] = original_display

assert(ok, err)
assert(#chat.messages == 2, "history messages must enter the message stack")
assert(chat.messages[1].role == "user" and chat.messages[2].role == "llm", "history role order")
assert(
  rendered[#rendered].role == "user" and rendered[#rendered].content == "  draft after slash  \n\ntail  \n",
  "editable draft tail must be preserved byte-for-byte"
)
assert(not vim.tbl_contains(chat.messages, rendered[#rendered]), "editable draft must not be committed")
assert(chat.header_line > 1, "latest editable user header must be tracked")

local context_lines = { "> Context:", "> - <file>example.lua</file>", "" }
local context_row = chat.header_line + 1
api.nvim_buf_set_lines(bufnr, context_row, context_row, false, context_lines)
chat.context.clear_rendered = function()
  api.nvim_buf_set_lines(bufnr, context_row, context_row + #context_lines, false, {})
end
local before_messages = vim.deepcopy(chat.messages)
local before_lines = api.nvim_buf_get_lines(bufnr, 0, -1, false)
ui.render = function() error("render failed") end
package.loaded[display_name] = {
  build_render_messages = function(messages) return vim.deepcopy(messages) end,
  apply_render_postprocess = function() end,
}
local rollback_ok = Chat.add_visible_history(chat, {
  { role = "user", content = "new user" },
  { role = "llm", content = "new llm" },
}, nil)
package.loaded[display_name] = original_display
assert(not rollback_ok, "render failure must be reported")
assert(vim.deep_equal(chat.messages, before_messages), "render failure must roll back message stack")
assert(vim.deep_equal(api.nvim_buf_get_lines(bufnr, 0, -1, false), before_lines), "render failure must restore buffer")

api.nvim_buf_delete(bufnr, { force = true })
print("VISIBLE_MARKDOWN_HISTORY_OK")
