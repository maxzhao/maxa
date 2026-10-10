-- Run: nvim --headless -u NONE -l lua/maxa/mcphub/native_servers/subagent/tools/multi_agent/agent_chat_token_decision_test.lua
package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path

local deferred
package.loaded["maxa.mcphub.native_servers.subagent.completion_guard"] = {
  defer_for_token_decision = function(chat, callback)
    if chat.defer_token_completion then
      deferred = callback
      return true
    end
    return false
  end,
  is_token_terminal = function(chat)
    local action = chat._maxa_token_decision_last_action
    return action == "finish" or action == "interrupt"
  end,
  token_decision_action = function(chat)
    return chat._maxa_token_decision_last_action
  end,
}
package.loaded["maxa.session.compaction_messages"] = {}
package.loaded["maxa.mcphub.native_servers.subagent.tools.multi_agent.handoff_tool"] = {
  find_last_handoff_result = function()
    return false, nil
  end,
}
package.loaded["maxa.utils.log"] = {
  debug = function() end,
  error = function() end,
}
package.loaded["maxa.mcphub.native_servers.subagent.tools.multi_agent.mcp_handoff"] = {
  clear_active_context = function() end,
}

local old_defer = vim.defer_fn
vim.defer_fn = function(callback)
  callback()
end
vim.notify = function() end

local AgentChat = require("maxa.mcphub.native_servers.subagent.tools.multi_agent.agent_chat")
local agent = AgentChat.new({ name = "reviewer", role = "review" })
local response, handoff
agent.is_busy = true
agent._on_response = function(result, err, handoff_result)
  assert(err == nil)
  response, handoff = result, handoff_result
end
local chat = {
  messages = { { role = "llm", content = "finish summary" } },
  defer_token_completion = true,
}

agent:_on_chat_completed(chat)
assert(response == nil, "waiting token decision must not finish multi-agent response")
assert(type(deferred) == "function", "completion callback was not deferred")
chat.defer_token_completion = false
chat._maxa_token_decision_last_action = "finish"
deferred()
assert(response == "finish summary", "finish response was not returned")
assert(handoff and handoff.target == "user", "token finish must terminate multi-agent routing")
assert(handoff.token_threshold_action == "finish", "token finish action was not preserved")

vim.defer_fn = old_defer
print("agent_chat_token_decision_test: OK")
