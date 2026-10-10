-- filepath: lua/maxa/mcphub/native_servers/subagent/fork_context_spec.lua
-- Run: nvim --headless -l lua/maxa/mcphub/native_servers/subagent/fork_context_spec.lua
package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path

local fork_context = require("maxa.mcphub.native_servers.subagent.fork_context")
local messages = {
  { role = "system", content = "prefix" },
  { role = "user", content = "task" },
  { role = "assistant", tool_calls = { { id = "one" }, { id = "two" } } },
  { role = "tool", content = "sibling" },
}
local clean, batch = fork_context.build_clean_messages(messages, "one")
assert(batch == true)
assert(#clean == 2)
assert(clean[1].content == "prefix")
clean[1].content = "changed"
assert(messages[1].content == "prefix")

local fallback = fork_context.build_clean_messages({
  { role = "user", content = "x" },
  { role = "assistant", content = "", tool_calls = { { id = "pending" } } },
}, "missing")
assert(#fallback == 1)

local chat = { messages = {}, adapter = {} }
local resolved, id = fork_context.resolve_caller({
  maxa_ai = { chat = chat, tool = { function_call = { id = "call" } } },
})
assert(resolved == chat and id == "call")
assert(fork_context.resolve_caller(nil) == nil)

local legacy = fork_context.build_clean_messages({
  { role = "system", content = "prefix" },
  { role = "user", content = "old" },
  { role = "system", content = "boundary", _meta = { tag = "agent_boundary" } },
  { role = "system", content = "unknown", _meta = { tag = "future_system" } },
  {
    role = "assistant",
    content = "kept",
    tools = { calls = {
      { id = "pause", ["function"] = { name = "pause_loop" } },
      { id = "sibling", ["function"] = { name = "read" } },
    } },
  },
  { role = "user", content = "completed turn" },
}, "missing")
assert(legacy[3].role == "user")
assert(legacy[4].role == "system")
assert(#legacy[5].tools.calls == 1)
assert(legacy[5].tools.calls[1].id == "sibling")
print("fork_context tests: 2 passed, 0 failed")
