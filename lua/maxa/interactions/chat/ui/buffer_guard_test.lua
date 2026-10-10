-- Run: nvim --headless -u NONE -l lua/maxa/interactions/chat/ui/buffer_guard_test.lua
vim.opt.runtimepath:prepend(vim.fn.getcwd())
local guard = require("maxa.interactions.chat.ui.buffer_guard")
local cancelled_request, cancelled_tool, dispatched = 0, 0, 0
local chat = {
  bufnr = 987654,
  current_request = { cancel = function() cancelled_request = cancelled_request + 1 end },
  current_tool = { cancel = function() cancelled_tool = cancelled_tool + 1 end },
  dispatch = function(_, event) if event == "on_cancelled" then dispatched = dispatched + 1 end end,
}
assert(guard.abort(chat, "test") == true)
assert(cancelled_request == 1 and cancelled_tool == 1 and dispatched == 1)
assert(chat.current_request == nil and chat.current_tool == nil and chat.status == "stopped")
assert(guard.abort(chat, "test again") == true)
assert(cancelled_request == 1 and cancelled_tool == 1 and dispatched == 1, "abort must be idempotent")
print("BUFFER_GUARD_OK")
