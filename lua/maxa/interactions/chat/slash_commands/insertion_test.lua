-- Run: nvim --headless -u NONE -l lua/maxa/interactions/chat/slash_commands/insertion_test.lua
vim.opt.runtimepath:prepend(vim.fn.stdpath("data") .. "/lazy/plenary.nvim")
vim.opt.runtimepath:prepend(vim.fn.getcwd())

local api = vim.api
local bufnr = api.nvim_create_buf(false, true)
api.nvim_set_current_buf(bufnr)

local chat = {
  bufnr = bufnr,
  _last_role = "user",
  MESSAGE_TYPES = { LLM_MESSAGE = "llm_message", REASONING_MESSAGE = "reasoning_message", TOOL_MESSAGE = "tool_message" },
}
chat.ui = {
  folds = { create_tool_fold = function() end, create_reasoning_fold = function() end },
  last = function()
    local count = api.nvim_buf_line_count(bufnr)
    local line = api.nvim_buf_get_lines(bufnr, count - 1, count, false)[1] or ""
    return count - 1, #line, count
  end,
  write_text = function(_, start_row, start_col, end_row, end_col, lines)
    api.nvim_buf_set_text(bufnr, start_row, start_col, end_row, end_col, lines)
  end,
  unlock_buf = function() vim.bo[bufnr].modifiable = true end,
  lock_buf = function() vim.bo[bufnr].modifiable = false end,
  move_cursor = function() end,
  render_headers = function() end,
  set_header = function(_, lines, role)
    table.insert(lines, "## " .. role)
    table.insert(lines, "")
  end,
}
chat.builder = require("maxa.interactions.chat.ui.builder").new({ chat = chat })
chat.add_buf_message = function(self, data, opts)
  return self.builder:add_message(data, opts)
end

local insertion = require("maxa.interactions.chat.slash_commands.insertion")

api.nvim_buf_set_lines(bufnr, 0, -1, false, { "前置后置" })
local line, _, range = insertion.add(chat, { slash_anchor = { row = 0, col = #"前置" } }, { content = "内容" })
assert(line == 1, "single-line insertion result")
assert(api.nvim_get_current_line() == "前置内容后置", "multibyte prefix must be preserved")
assert(range.start.col == #"前置" and range["end"].col == #"前置内容", "write range must use byte columns")

chat.builder = require("maxa.interactions.chat.ui.builder").new({ chat = chat })
api.nvim_buf_set_lines(bufnr, 0, -1, false, { "xy" })
insertion.add(chat, { slash_anchor = { row = 0, col = 1 } }, { content = "A\nB" })
assert(vim.deep_equal(api.nvim_buf_get_lines(bufnr, 0, -1, false), { "xA", "By" }), "multiline insertion")

chat.builder = require("maxa.interactions.chat.ui.builder").new({ chat = chat })
api.nvim_buf_set_lines(bufnr, 0, -1, false, { "zz" })
api.nvim_win_set_cursor(0, { 1, 1 })
insertion.add(chat, { slash_anchor = { row = 99, col = 0 } }, { content = "Q" })
assert(api.nvim_get_current_line() == "zQz", "invalid anchor must fall back to current Chat cursor")

chat.builder = require("maxa.interactions.chat.ui.builder").new({ chat = chat })
api.nvim_buf_set_lines(bufnr, 0, -1, false, { "X" })
local sequential_context = { slash_anchor = { row = 0, col = 1 } }
insertion.add(chat, sequential_context, { content = "A" })
insertion.add(chat, sequential_context, { content = "B" })
assert(api.nvim_get_current_line() == "XAB", "multiple visible outputs must preserve source order")

local cancelled_context = { slash_anchor = { row = 0, col = 1 } }
assert(insertion.track_context(chat, cancelled_context), "async invocation anchor")
insertion.discard_anchor(chat, cancelled_context)
assert(cancelled_context.slash_anchor_extmark == nil, "cancelled invocation must release anchor")
insertion.discard_anchor(chat, cancelled_context)

vim.bo[bufnr].modifiable = true
api.nvim_buf_set_lines(bufnr, 0, -1, false, { "prefix /now tail" })
local completion = require("maxa.providers.completion")
local rejected = completion.prepare_slash_command({ label = "/now", context = {} }, chat, bufnr, {
  start = { row = 0, col = 0 },
  ["end"] = { row = 0, col = 4 },
})
assert(not rejected and api.nvim_get_current_line() == "prefix /now tail", "mismatched ranges must not delete text")

chat.header_line = 1
api.nvim_buf_set_lines(bufnr, 0, -1, false, { "/now" })
local historical = completion.prepare_slash_command({ label = "/now", context = {} }, chat, bufnr, {
  start = { row = 0, col = 0 },
  ["end"] = { row = 0, col = 4 },
})
assert(not historical and api.nvim_get_current_line() == "/now", "ranges outside editable input must be rejected")
chat.header_line = nil

api.nvim_buf_set_lines(bufnr, 0, -1, false, { "keep /now tail" })
local selected = { label = "/now", config = {}, context = {} }
local prepared, err = completion.prepare_slash_command(selected, chat, bufnr, {
  start = { row = 0, col = 5 },
  ["end"] = { row = 0, col = 9 },
})
assert(prepared, err)
assert(api.nvim_get_current_line() == "keep  tail", "only slash token may be deleted")
assert(selected.context.slash_anchor.row == 0 and selected.context.slash_anchor.col == 5, "slash anchor")

assert(insertion.track_context(chat, selected.context), "async text command must create tracked anchor")
api.nvim_buf_set_text(bufnr, 0, 0, 0, 0, { "XX" })
chat.builder = require("maxa.interactions.chat.ui.builder").new({ chat = chat })
insertion.add(chat, selected.context, { content = "R" })
assert(api.nvim_get_current_line() == "XXkeep R tail", "tracked anchor must follow edits before async output")

api.nvim_buf_delete(bufnr, { force = true })
print("SLASH_INSERTION_OK")
