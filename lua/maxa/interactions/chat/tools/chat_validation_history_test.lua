-- Run: nvim --headless -u NONE -l lua/maxa/interactions/chat/tools/chat_validation_history_test.lua
vim.opt.runtimepath:prepend(vim.fn.getcwd())
for _, dependency in ipairs({ "plenary.nvim", "nui.nvim" }) do
  local path = vim.fn.stdpath("data") .. "/lazy/" .. dependency
  if vim.fn.isdirectory(path) == 1 then
    vim.opt.runtimepath:prepend(path)
  end
end
package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path

local Chat = require("maxa.interactions.chat")
local anthropic = require("maxa.adapters.http.anthropic")
local gemini = require("maxa.adapters.http.gemini")
local openai = require("maxa.adapters.http.openai")

local calls = {
  {
    id = "call-valid",
    type = "function",
    provider_meta = "keep-valid",
    ["function"] = { name = "write", arguments = [[{"path":"a","content":"b"}]] },
  },
  {
    id = "call-rejected",
    type = "function",
    provider_meta = "keep-rejected",
    ["function"] = { name = "write", arguments = [[{"path":"a"}]] },
  },
  {
    type = "function",
    provider_meta = "unreplayable",
    ["function"] = { name = "write", arguments = [[{"path":"a"}]] },
  },
}
local original = vim.deepcopy(calls)
local added = {}
local captured_plan
local chat = setmetatable({
  adapter = openai,
  status = "success",
  current_request = {},
  messages = {},
  cycle = 1,
  tool_registry = {
    schemas = {
      ["<tool>write</tool>"] = {
        type = "function",
        ["function"] = {
          name = "write",
          parameters = {
            type = "object",
            properties = { path = { type = "string" }, content = { type = "string" } },
            required = { "path", "content" },
          },
        },
      },
    },
  },
}, { __index = Chat })
chat.tools = {
  adapter = openai,
  execute = function(_, owner, plan)
    assert(owner == chat)
    captured_plan = plan
  end,
}
function chat:add_message(data, opts)
  added[#added + 1] = { data = data, opts = opts }
  return self
end
function chat:label_sent_items() end

chat:done(nil, nil, calls, nil, {})

assert(vim.deep_equal(calls, original), "Chat validation mutated canonical calls")
assert(#added == 1, "Chat should store one filtered assistant tool-call message")
assert(added[1].opts.visible == false)
assert(#added[1].data.tool_calls == 2, "unreplayable call remained in structured history")
assert(added[1].data.tool_calls[1].provider_meta == "keep-valid")
assert(added[1].data.tool_calls[2].provider_meta == "keep-rejected")
assert(captured_plan and #captured_plan.entries == 3)
assert(captured_plan.entries[1].kind == "valid")
assert(captured_plan.entries[2].kind == "rejected_replayable")
assert(captured_plan.entries[3].kind == "rejected_unreplayable")
assert(#captured_plan.corrections == 1)

local anthropic_chat = setmetatable({
  adapter = anthropic,
  messages = {},
  cycle = 1,
}, { __index = Chat })
local rejected_tool = {
  name = "write",
  function_call = {
    id = "toolu_rejected",
    type = "function",
    ["function"] = { name = "write", arguments = [[{"path":"a"}]] },
  },
}
anthropic_chat:add_validation_error_output(rejected_tool, "TOOL_CALL_ERROR\nThe tool was not executed.")
assert(#anthropic_chat.messages == 1, "validation result was not stored")
assert(anthropic_chat.messages[1].tools.is_error == true, "stored Anthropic result lost is_error")
assert(anthropic_chat.messages[1]._meta.is_error == true, "stored result metadata lost is_error")
local wire = anthropic.handlers.form_messages(anthropic, {
  {
    role = "assistant",
    tools = { calls = { rejected_tool.function_call } },
  },
  vim.deepcopy(anthropic_chat.messages[1]),
})
assert(wire.messages[2].content[1].is_error == true, "Anthropic wire tool_result lost is_error=true")

local gemini_call = {
  id = "call_signed",
  type = "function",
  thought_signature = "provider-signature",
  ["function"] = { name = "write", arguments = [[{"path":"a"}]] },
}
local gemini_wire = gemini.handlers.form_messages(gemini, {
  { role = "assistant", tools = { calls = { gemini_call } } },
})
assert(gemini_wire.messages[1].tool_calls[1].thought_signature == "provider-signature", "Gemini signature changed")
assert(gemini_wire.messages[1].tool_calls[1]["function"].arguments == gemini_call["function"].arguments)

print("chat_validation_history_test: 14 passed, 0 failed")
