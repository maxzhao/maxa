-- Actual Builder/UI boundary regression for byte-for-byte ask Chat input.
-- Run: nvim --headless -u NONE -l lua/maxa/interactions/chat/tools/builtin/tests/ask_real_buffer_test.lua
vim.opt.runtimepath:prepend(vim.fn.getcwd())
vim.opt.runtimepath:prepend(vim.fn.stdpath("data") .. "/lazy/plenary.nvim")
package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path

local Builder = require("maxa.interactions.chat.ui.builder")
local UI = require("maxa.interactions.chat.ui")
local config = require("maxa.config")
local runtime = require("maxa.interactions.chat.tools.builtin.runtime.ask")

local bufnr = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(bufnr)
vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "base" })
local aug = vim.api.nvim_create_augroup("MaxaAskRealBuilderTest", { clear = true })
local chat = {
  bufnr = bufnr,
  id = 1,
  aug = aug,
  _last_role = config.constants.LLM_ROLE,
  header_line = 1,
  MESSAGE_TYPES = { TOOL_MESSAGE = "tool", REASONING_MESSAGE = "reasoning" },
  callbacks = {},
  opts = { cwd = vim.fn.getcwd(), project_root = vim.fn.getcwd(), save_id = "ask-real-buffer" },
}
chat.ui = UI.new({
  adapter = { formatted_name = "Test" },
  aug = aug,
  chat_bufnr = bufnr,
  chat_id = chat.id,
  roles = config.interactions.chat.roles,
  settings = {},
  tokens = 0,
  winnr = 0,
})
chat.builder = Builder.new({ chat = chat })
function chat:add_buf_message(data, opts)
  return self.builder:add_message(data, opts)
end
function chat:add_callback(event, callback)
  self.callbacks[event] = self.callbacks[event] or {}
  table.insert(self.callbacks[event], callback)
end

local cancelled = 0
local fake_client = {}
function fake_client.create_human_assist_input(_, callback)
  fake_client.create_callback = callback
end
function fake_client.cancel_human_assist(_, callback)
  cancelled = cancelled + 1
  if callback then
    callback(true, { status = "cancelled" }, {})
  end
end
function fake_client.error_message()
  return "offline"
end
runtime._test_set_client(fake_client)

local result
assert(runtime.start(chat, { mode = "input", message = "Reply", timeout = 0 }, function(ok, value)
  result = { ok, value }
end, { request_id = "ask-real-buffer" }))
local state = assert(runtime._test_active(chat))
assert(state.input_clear_start_row < state.input_start_row, "input section and raw content ranges were not separated")
local section =
  table.concat(vim.api.nvim_buf_get_lines(bufnr, state.input_clear_start_row, state.input_start_row, false), "\n")
assert(section:find("## Me", 1, true), "real Builder user header was not inside the clear range")
local initial_content = vim.api.nvim_buf_get_lines(bufnr, state.input_start_row, -1, false)
assert(vim.deep_equal(initial_content, { "" }), "raw content range includes Builder header or spacing")

local answer = "  leading and trailing  \n\n> quote stays\nlast line  \n"
vim.bo[bufnr].modifiable = true
vim.api.nvim_buf_set_lines(bufnr, state.input_start_row, -1, false, vim.split(answer, "\n", { plain = true }))
assert(runtime.submit(chat, {}))
assert(vim.deep_equal(result, { true, answer }), "ask result was not byte-for-byte exact: " .. vim.inspect(result))
assert(cancelled == 1, "Chat-first completion did not reserve Bridge cancellation")
local remaining = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
assert(not remaining:find("## Me", 1, true), "ask input header remained after completion")

runtime._test_reset()
vim.api.nvim_del_augroup_by_id(aug)
vim.api.nvim_buf_delete(bufnr, { force = true })
print("ask_real_buffer_test: OK")
