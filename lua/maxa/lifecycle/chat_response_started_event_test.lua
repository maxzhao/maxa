-- filepath: lua/maxa/lifecycle/chat_response_started_event_test.lua
-- Unit test: MaxaAIChatResponseStarted fires once when assistant content starts rendering.

local passed = 0
local failed = 0

local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then
    passed = passed + 1
    print("✓ " .. name)
  else
    failed = failed + 1
    print("✗ " .. name)
    print("  Error: " .. tostring(err))
  end
end

local function assert_equal(expected, actual, msg)
  if expected ~= actual then
    error(string.format("%s: expected %s, got %s", msg or "assertion failed", vim.inspect(expected), vim.inspect(actual)))
  end
end

print("\n=== Testing chat_response_started_event ===\n")

test("fires MaxaAIChatResponseStarted once when LLM content renders", function()
  local Chat = {
    MESSAGE_TYPES = {
      LLM_MESSAGE = "llm_message",
      REASONING_MESSAGE = "reasoning_message",
      TOOL_MESSAGE = "tool_message",
    },
  }
  Chat.__index = Chat

  function Chat:_submit_http(payload)
    self.submitted_payload = payload
    return true
  end

  function Chat:add_buf_message(data, opts)
    table.insert(self.rendered_messages, { data = data, opts = opts })
    return true
  end

  package.loaded["maxa.interactions.chat"] = Chat
  package.loaded["maxa.lifecycle.chat_response_started_event"] = nil
  local hook = require("maxa.lifecycle.chat_response_started_event")
  assert_equal(true, hook.setup(), "listener setup")

  local events = {}
  local group = vim.api.nvim_create_augroup("test_chat_response_started_event", { clear = true })
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "MaxaAIChatResponseStarted",
    callback = function(args)
      table.insert(events, args.data)
    end,
  })

  local chat = setmetatable({ bufnr = 123, id = 456, rendered_messages = {} }, Chat)

  hook.observe(chat, { type = "user_message" })
  chat:add_buf_message({ role = "user", content = "hello" }, { type = "user_message" })
  hook.observe(chat, { type = Chat.MESSAGE_TYPES.TOOL_MESSAGE })
  chat:add_buf_message({ role = "tool", content = "tool" }, { type = Chat.MESSAGE_TYPES.TOOL_MESSAGE })
  assert_equal(0, #events, "non-assistant messages do not fire")

  hook.reset(chat)
  chat:_submit_http({ round = 1 })
  hook.observe(chat, { type = Chat.MESSAGE_TYPES.LLM_MESSAGE })
  chat:add_buf_message({ role = "assistant", content = "first" }, { type = Chat.MESSAGE_TYPES.LLM_MESSAGE })
  hook.observe(chat, { type = Chat.MESSAGE_TYPES.LLM_MESSAGE })
  chat:add_buf_message({ role = "assistant", content = "second" }, { type = Chat.MESSAGE_TYPES.LLM_MESSAGE })
  hook.observe(chat, { type = Chat.MESSAGE_TYPES.REASONING_MESSAGE })
  chat:add_buf_message({ role = "assistant", content = "reasoning" }, { type = Chat.MESSAGE_TYPES.REASONING_MESSAGE })

  assert_equal(1, #events, "event fired once for first submit")
  assert_equal(123, events[1].bufnr, "event bufnr")
  assert_equal(456, events[1].id, "event id")

  hook.reset(chat)
  chat:_submit_http({ round = 2 })
  hook.observe(chat, { type = Chat.MESSAGE_TYPES.LLM_MESSAGE })
  chat:add_buf_message({ role = "assistant", content = "next round" }, { type = Chat.MESSAGE_TYPES.LLM_MESSAGE })
  assert_equal(2, #events, "event fires again after next submit")
  assert_equal(6, #chat.rendered_messages, "original add_buf_message still called")
end)

print(string.format("\n=== Results: %d passed, %d failed ===\n", passed, failed))
if failed > 0 then
  os.exit(1)
else
  os.exit(0)
end
