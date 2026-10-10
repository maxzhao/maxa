-- Test ToolCallsCompleted AbilityHook event batching and pre/post phases.
-- Run with: nvim --headless -u NONE -l lua/maxa/lifecycle/tool_calls_completed_event_test.lua

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

local mod
local Chat = {}
Chat.__index = Chat

function Chat:add_tool_output(tool, for_llm, _for_user)
  local fc = tool.function_call
  table.insert(self.messages, {
    role = "tool",
    content = for_llm,
    tools = {
      call_id = fc.id,
      id = fc.call_id,
    },
  })
  mod.record_output(self, tool, for_llm, _for_user)
  return true
end

package.loaded["maxa.interactions.chat"] = Chat

local chats = {}
package.loaded["maxa"] = {
  buf_get_chat = function(bufnr)
    return chats[bufnr]
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

mod = require("maxa.lifecycle.tool_calls_completed_event")
mod.setup()

local function new_chat(id, bufnr)
  local chat = setmetatable({ id = id, bufnr = bufnr, messages = {} }, Chat)
  chats[bufnr] = chat
  return chat
end

local function fire_tools_finished(bufnr, id)
  vim.api.nvim_exec_autocmds("User", {
    pattern = "MaxaAIToolsFinished",
    data = { bufnr = bufnr, id = id },
  })
  vim.wait(100, function()
    return #events >= 2
  end)
end

-- Single tool call: pre and post both fire, payload is normalized.
do
  events = {}
  local chat = new_chat(1001, 9001)
  local calls = {
    { id = "call_single", ["function"] = { name = "demo__one", arguments = '{"x":1}' } },
  }
  mod.start_batch(chat, calls)
  chat:add_tool_output({ function_call = calls[1] }, "single result", "")
  fire_tools_finished(chat.bufnr, 111)

  assert_eq(#events, 2, "single batch should fire pre and post once each")
  assert_eq(events[1].phase, "pre", "first event should be pre")
  assert_eq(events[2].phase, "post", "second event should be post")
  assert_eq(events[1].name, "ToolCallsCompleted", "event name")
  assert_eq(events[1].data.mode, "single", "single mode")
  assert_eq(events[1].data.call_count, 1, "single call count")
  assert_eq(events[1].data.calls[1].tool_id, "demo__one", "single tool id")
  assert_eq(events[1].data.calls[1].arguments.x, 1, "decoded arguments")
  assert_eq(events[1].data.calls[1].result.content, "single result", "result content")
end

-- Multiple MaxaAI tool calls: still one pre and one post event for the batch.
do
  events = {}
  local chat = new_chat(1002, 9002)
  local calls = {
    { id = "call_a", ["function"] = { name = "demo__a", arguments = '{"a":true}' } },
    { id = "call_b", ["function"] = { name = "demo__b", arguments = '{"b":2}' } },
  }
  mod.start_batch(chat, calls)
  chat:add_tool_output({ function_call = calls[1] }, "A", "")
  chat:add_tool_output({ function_call = calls[2] }, "B", "")
  fire_tools_finished(chat.bufnr, 222)

  assert_eq(#events, 2, "multi batch should fire pre and post once each")
  assert_eq(events[1].data.mode, "batch", "batch mode")
  assert_eq(events[1].data.call_count, 2, "batch call count")
  assert_eq(events[1].data.calls[1].result.content, "A", "first result")
  assert_eq(events[1].data.calls[2].result.content, "B", "second result")
end

-- multicall exposes a nested_batch when arguments/result JSON can be decoded.
do
  events = {}
  local chat = new_chat(1003, 9003)
  local args = vim.json.encode({
    title = "nested",
    calls = {
      { label = "one", tool = "demo__one", params = "{}" },
      { label = "two", tool = "demo__two", params = "{}" },
    },
  })
  local result = vim.json.encode({
    ok = true,
    results = {
      { label = "one", tool = "demo__one", ok = true, result = "1" },
      { label = "two", tool = "demo__two", ok = true, result = "2" },
    },
  })
  local calls = {
    { id = "call_parallel", ["function"] = { name = "multicall", arguments = args } },
  }
  mod.start_batch(chat, calls)
  chat:add_tool_output({ function_call = calls[1] }, result, "")
  fire_tools_finished(chat.bufnr, 333)

  local nested = events[1].data.calls[1].nested_batch
  assert(nested, "nested_batch should be present")
  assert_eq(nested.kind, "builtin_multicall", "nested kind")
  assert_eq(nested.call_count, 2, "nested call count")
end

-- Validation rejections expose only the bounded snapshot to lifecycle hooks.
do
  events = {}
  local chat = new_chat(1004, 9004)
  local call = {
    id = "call_rejected",
    ["function"] = { name = "write", arguments = vim.json.encode({ content = string.rep("x", 5000) }) },
  }
  local plan = {
    calls = { call },
    entries = {
      {
        kind = "rejected_replayable",
        call = call,
        snapshot = '{"content":"bounded"}',
        reason = "Missing required parameter: path",
        reason_code = "missing_required",
        received_chars = 5014,
      },
    },
  }
  mod.start_batch(chat, plan)
  chat:add_tool_output({
    function_call = call,
    validation_snapshot = plan.entries[1].snapshot,
    _maxa_validation_rejection = plan.entries[1],
  }, "rejected", "")
  fire_tools_finished(chat.bufnr, 444)

  local completed = events[1].data.calls[1]
  assert_eq(completed.arguments_raw, plan.entries[1].snapshot, "validation snapshot was not bounded")
  assert_eq(completed.arguments, nil, "large rejected arguments were decoded into lifecycle payload")
  assert_eq(completed.validation.reason_code, "missing_required", "validation metadata missing")
end

-- A user-cancelled batch must not produce completion hooks that can start new lifecycle work.
do
  events = {}
  local chat = new_chat(1005, 9005)
  local calls = {
    { id = "call_cancelled", ["function"] = { name = "ask", arguments = '{"mode":"input"}' } },
  }
  mod.start_batch(chat, calls)
  chat:add_tool_output({ function_call = calls[1] }, "ask cancelled", "")
  vim.api.nvim_exec_autocmds("User", {
    pattern = "MaxaAIToolsFinished",
    data = { bufnr = chat.bufnr, id = 555, cancelled = true },
  })
  vim.wait(20, function()
    return false
  end)
  assert_eq(#events, 0, "cancelled batch must not fire ToolCallsCompleted")
end

print("tool_calls_completed_event_test: OK")
