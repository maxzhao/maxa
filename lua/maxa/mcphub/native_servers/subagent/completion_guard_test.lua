-- Run: nvim --headless -u NONE -l lua/maxa/mcphub/native_servers/subagent/completion_guard_test.lua
package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path

local function eq(expected, actual)
  assert(expected == actual, "expected " .. vim.inspect(expected) .. ", got " .. vim.inspect(actual))
end

local original = package.loaded["maxa.lifecycle.chat_token_threshold_decision"]
package.loaded["maxa.mcphub.native_servers.subagent.completion_guard"] = nil
local guard = require("maxa.mcphub.native_servers.subagent.completion_guard")
local chat = {}
local callback = function() end

package.loaded["maxa.lifecycle.chat_token_threshold_decision"] = nil
eq(false, guard.defer_for_token_decision(chat, callback))

local received_chat, received_callback
package.loaded["maxa.lifecycle.chat_token_threshold_decision"] = {
  defer_completion = function(c, cb)
    received_chat, received_callback = c, cb
    return true
  end,
}
eq(true, guard.defer_for_token_decision(chat, callback))
eq(chat, received_chat)
eq(callback, received_callback)

eq(false, guard.is_token_terminal(chat))
chat._maxa_token_decision_last_action = "finish"
eq(true, guard.is_token_terminal(chat))
chat._maxa_token_decision_last_action = "interrupt"
eq(true, guard.is_token_terminal(chat))
chat._maxa_token_decision_last_action = "compact"
eq(false, guard.is_token_terminal(chat))

package.loaded["maxa.lifecycle.chat_token_threshold_decision"] = original
print("completion_guard_test: OK")
