-- filepath: lua/maxa/interactions/chat/tools/builtin/tests/image_analysis_maxa_ai_integration_test.lua
-- Real installed Maxa AI Chat/UI lifecycle with a controlled adapter dispatch.
-- Run: nvim --headless -l lua/maxa/interactions/chat/tools/builtin/tests/image_analysis_maxa_ai_integration_test.lua
local data = vim.fn.stdpath("data") .. "/lazy/"
vim.opt.runtimepath:prepend(data .. "plenary.nvim")
vim.opt.runtimepath:prepend(data .. "nui.nvim")
vim.opt.runtimepath:prepend(vim.fn.stdpath("config"))
package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path

local adapters = require("maxa.adapters")
local base = require("maxa.adapters.http.openai_responses")
local adapter = adapters.extend("openai_responses", {
  name = "image-analysis-integration",
  opts = { stream = false, vision = true },
  env = { api_key = "test" },
  url = "http://127.0.0.1/never-sent",
  schema = base.schema,
  handlers = base.handlers,
})
local Chat = require("maxa.interactions.chat")
local controller = require("maxa.interactions.chat.tools.builtin.runtime.image_analysis_controller")
local history_core = require("maxa.session.history_core")
local utils = require("maxa.mcphub.native_servers.subagent.utils")

local parent_buf = vim.api.nvim_create_buf(false, true)
local windows_before = #vim.api.nvim_list_wins()
local opened = 0
local UI = require("maxa.interactions.chat.ui")
local real_open = UI.open
UI.open = function(self, ...)
  opened = opened + 1
  return real_open(self, ...)
end
local messages = {
  { role = "system", content = "prefix", opts = { visible = false } },
  { role = "user", content = "task", opts = { visible = false } },
  { role = "assistant", content = "", opts = { visible = false } },
}
local ok, child = utils.with_subagent_chat_creation(Chat, function()
  return Chat.new({
    adapter = adapter,
    auto_submit = false,
    buffer_context = {
      bufnr = parent_buf,
      buftype = "nofile",
      filetype = "",
      filename = "",
      cursor_pos = { 1, 0 },
      lines = {},
      line_count = 1,
      mode = "n",
      is_visual = false,
    },
    ignore_system_prompt = true,
    intro_message = "",
    messages = messages,
    save_id = history_core.make_unsavable_save_id("analyze"),
    title = "Temporary image analysis",
  })
end, { hidden = true, restore_last_chat = true })
UI.open = real_open
assert(ok and child, tostring(child))
assert(opened == 0, "hidden Chat.new must not call the real UI.open")
assert(#vim.api.nvim_list_wins() == windows_before, "hidden child changed window count")
assert(history_core.is_unsavable_save_id(child.opts.save_id, "analyze"), "child must be unsavable")
-- The real history storage guard is source-owned and directly keyed to this ID;
-- exercise that predicate here without loading the full configured extension.
assert(history_core.is_unsavable_save_id(child.opts.save_id), "history guard must reject child persistence")

child.messages = messages
child.tools.messages = messages
local terminal
local dispatched = 0
-- Replace only the transport boundary; real Chat:submit still builds and
-- dispatches the installed adapter payload through this controlled stub.
child._submit_http = function(self)
  dispatched = dispatched + 1
  self.current_request = { cancel = function() end }
end
local state = controller.install({
  chat = child,
  max_steps = 1,
  on_terminal = function(...)
    terminal = { ... }
  end,
})

child:submit({ auto_submit = true })
assert(dispatched == 1 and state.steps_used == 1, "first request must count at actual dispatch")
vim.wait(20)
assert(terminal == nil, "analysis must wait for active request completion")
child.status = "success"
child:done({ "# integrated analysis\n\nFinal response." }, nil, nil, nil)
vim.wait(100, function()
  return terminal ~= nil
end)
assert(terminal and terminal[1] == "completed" and terminal[3] == 1, "final-text completion failed")
assert(terminal[2] == "# integrated analysis\n\nFinal response.", "final text was not preserved")
assert(not vim.api.nvim_buf_is_valid(child.bufnr), "child buffer leaked")
assert(#vim.api.nvim_list_wins() == windows_before, "cleanup changed window count")
local before = dispatched
child:submit({ auto_submit = true })
assert(dispatched == before, "stale callback dispatched after disposal")
print("image_analysis MaxaAI integration: 1 passed, 0 failed")
