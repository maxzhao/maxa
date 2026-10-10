-- Test ChatSubmitted AbilityHook payload classification.
-- Run with: nvim --headless -u NONE -l lua/maxa/lifecycle/chat_submitted_event_test.lua

package.path = table.concat({
  vim.fn.getcwd() .. "/lua/?.lua",
  vim.fn.getcwd() .. "/lua/?/init.lua",
  package.path,
}, ";")

local function assert_eq(actual, expected, message)
  if actual ~= expected then
    error(string.format("%s\nexpected=%s\nactual=%s", message or "assert_eq failed", vim.inspect(expected), vim.inspect(actual)), 2)
  end
end

local Chat = {}
Chat.__index = Chat
function Chat.submit(self, opts)
  if not require("maxa.lifecycle.chat_submitted_event").before_submit(self, opts) then
    return nil
  end
  self.original_submit_called = (self.original_submit_called or 0) + 1
  self.original_submit_opts = opts
  return "submitted"
end
function Chat.add_message(self, data, opts)
  data, opts = require("maxa.lifecycle.chat_submitted_event").normalize_message(self, data, opts)
  self.messages[#self.messages + 1] = vim.tbl_extend("force", vim.deepcopy(data), opts or {})
  return self
end

package.loaded["maxa.interactions.chat"] = Chat
package.loaded["maxa.interactions.chat.parser"] = {
  messages = function(chat, _header_line)
    if chat.pending_content then
      return { content = chat.pending_content }
    end
    return nil
  end,
}

local events = {}
package.loaded["maxa.abilities.hooks.fire"] = {
  fire_sync = function(name, data)
    table.insert(events, { phase = "pre", name = name, data = data })
  end,
  fire = function(name, data)
    table.insert(events, { phase = "post", name = name, data = data })
  end,
}

require("maxa.lifecycle.chat_submitted_event").setup()

local function new_chat(extra)
  extra = extra or {}
  local chat = setmetatable(vim.tbl_extend("force", {
    id = 123,
    bufnr = 456,
    header_line = 1,
    messages = {},
    pending_content = nil,
  }, extra), Chat)
  return chat
end

-- Upstream rules helper runs in on_created after Chat has a user message. Its tagged
-- system fragment is converted at the project adapter boundary; unrelated dynamic
-- systems remain a hard error and are later guarded again by Responses build_messages.
do
  local chat = new_chat({ messages = { { role = "user", content = "task" } } })
  chat:add_message({ role = "system", content = "rules guidance" }, { _meta = { tag = "rules" } })
  assert_eq(chat.messages[2].role, "user", "late rules system becomes user context")
  assert_eq(chat.messages[2].content, "rules guidance", "rules content is preserved")
end
do
  local chat = new_chat({ messages = { { role = "user", content = "task" } } })
  local ok, err = pcall(chat.add_message, chat, { role = "system", content = "unknown" }, {})
  assert_eq(ok, false, "unknown late system is rejected")
  assert(tostring(err):find("dynamic system messages are forbidden", 1, true))
end

-- Direct user buffer submit: is_user_input=true and user_message comes from parser.messages.
do
  events = {}
  local chat = new_chat({ pending_content = "hello from buffer" })
  local result = chat:submit()
  assert_eq(result, "submitted", "original submit result")
  assert_eq(#events, 2, "manual submit should fire pre and post")
  assert_eq(events[1].data.is_user_input, true, "manual is user input")
  assert_eq(events[1].data.auto_submit, false, "manual auto_submit")
  assert_eq(events[1].data.user_message, "hello from buffer", "manual user_message")
end

-- auto_submit submits existing messages, not direct user input.
do
  events = {}
  local chat = new_chat({ pending_content = "ignored" })
  chat:submit({ auto_submit = true })
  assert_eq(#events, 2, "auto submit should also fire ChatSubmitted")
  assert_eq(events[1].data.is_user_input, false, "auto submit is not user input")
  assert_eq(events[1].data.auto_submit, true, "auto submit flag")
  assert_eq(events[1].data.user_message, "", "auto submit user_message empty")
end

-- repeat-controlled submits are not direct user input even if parser can see buffer content.
do
  events = {}
  local chat = new_chat({ pending_content = "repeat content", _repeat_state = { active = true } })
  chat:submit()
  assert_eq(#events, 2, "repeat submit should fire ChatSubmitted")
  assert_eq(events[1].data.is_user_input, false, "repeat is not user input")
  assert_eq(events[1].data.auto_submit, false, "repeat can be non-auto_submit")
  assert_eq(events[1].data.user_message, "", "repeat user_message empty")
end

-- regenerate/callback-driven submits are not fresh manual user prompts.
do
  events = {}
  local chat = new_chat({ pending_content = "regenerate content" })
  chat:submit({ regenerate = true })
  assert_eq(#events, 2, "regenerate should fire ChatSubmitted")
  assert_eq(events[1].data.is_user_input, false, "regenerate is not user input")
  assert_eq(events[1].data.user_message, "", "regenerate user_message empty")
end

do
  events = {}
  local chat = new_chat({ pending_content = "callback content" })
  chat:submit({ callback = function() end })
  assert_eq(#events, 2, "callback submit should fire ChatSubmitted")
  assert_eq(events[1].data.is_user_input, false, "callback submit is not user input")
  assert_eq(events[1].data.user_message, "", "callback submit user_message empty")
end

print("chat_submitted_event_test: OK")
