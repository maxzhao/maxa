-- filepath: lua/maxa/interactions/chat/tools/builtin/tests/ttl_repeat_read_spec.lua
-- Run: nvim --headless -u NONE -l lua/maxa/interactions/chat/tools/builtin/tests/ttl_repeat_read_spec.lua
package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path

local ttl = require("maxa.interactions.chat.tools.builtin.runtime.ttl_result")
local function add_read(chat, id, name, args, content)
  local call = { id = id, ["function"] = { name = name or "read", arguments = args } }
  chat.messages[#chat.messages + 1] = { role = "assistant", tools = { calls = { call } } }
  local result = { role = "tool", tools = { call_id = id }, content = content or "file body" }
  chat.messages[#chat.messages + 1] = result
  assert(ttl.attach_to_tool_result(chat, result, id, { ttl = 3, cleanup = "content" }))
  return result
end

local function expire(chat)
  for _ = 1, 3 do
    chat.messages[#chat.messages + 1] = { role = "assistant", content = "gather another result" }
  end
  assert(ttl.before_chat_submit(chat) > 0)
end

local function has_warning(msg)
  return msg.content:find("ttl_notice: identical read previously expired", 1, true) ~= nil
end

local original = { path = "/tmp/a.txt", result_policy = "temporary", start_line = 1, end_line = -1 }
local chat = { messages = {} }
local first = add_read(chat, "old", "read", vim.json.encode(original))
expire(chat)
assert(first._meta.ttl_result.expired and first.content:find("TTL reached", 1, true))
local repeated = add_read(chat, "new", "read", '{"end_line":-1,"path":"/tmp/a.txt","start_line":1,"result_policy":"temporary"}', "fresh body")
assert(has_warning(repeated) and repeated.content:find("tool_call_id: new", 1, true))
assert(repeated.content:match("\n%-%-%-\nfresh body$"))
assert(not repeated.content:find("<!-- maxa-ttl-result:start -->", 1, true))
assert(repeated._meta.ttl_result.ttl == 3)
assert(ttl.apply_action(chat, "new", "defer", 2))
assert(has_warning(repeated) and select(2, repeated.content:gsub("ttl_notice: identical read previously expired", "")) == 1)
assert(ttl.apply_action(chat, "new", "keep"))
assert(repeated.content == "fresh body" and repeated._meta.ttl_result.policy == "keep")
local after_keep = add_read(chat, "after-keep", "read", vim.json.encode(original))
assert(not has_warning(after_keep), "latest matching result was kept")

local wrapped = { messages = {} }
local wrapped_first = add_read(wrapped, "wrapped-old", "call", vim.json.encode({ tool = "read", params = original }))
expire(wrapped)
assert(wrapped_first._meta.ttl_result.expired)
local wrapped_repeat = add_read(wrapped, "wrapped-new", "call", {
  tool = "read", params = vim.json.encode({ result_policy = "temporary", end_line = -1, start_line = 1, path = "/tmp/a.txt" }),
})
assert(has_warning(wrapped_repeat) and wrapped_repeat.content:find("tool_call_id: wrapped-new", 1, true))

local current = { messages = {} }
add_read(current, "legacy", "call", { tool = "read", params = original })
expire(current)
local new_run = add_read(current, "current", "run", {
  title = "same read", scope = "tool", command = "read", args = vim.json.encode(original), opts = '{"async":false}',
})
assert(has_warning(new_run))
local async_read = { messages = {} }
add_read(async_read, "old", "read", original)
expire(async_read)
assert(not has_warning(add_read(async_read, "async", "run", {
  title = "async read", scope = "tool", command = "read", args = vim.json.encode(original), opts = '{"async":true}',
})))

local mismatch = { messages = {} }
add_read(mismatch, "mismatch-old", "read", vim.json.encode(original))
expire(mismatch)
assert(not has_warning(add_read(mismatch, "other-range", "read", vim.json.encode({
  path = "/tmp/a.txt", result_policy = "temporary", start_line = 2, end_line = -1,
}))))
local discarded = { messages = {} }
add_read(discarded, "discarded-old", "read", vim.json.encode(original))
assert(ttl.apply_action(discarded, "discarded-old", "discard"))
assert(not has_warning(add_read(discarded, "after-discard", "read", vim.json.encode(original))))
local ordinary = { messages = {} }
add_read(ordinary, "run-old", "run", vim.json.encode(original))
expire(ordinary)
assert(not has_warning(add_read(ordinary, "run-new", "run", vim.json.encode(original))))

-- Runtime metadata removal must not consume matching source text.
local literal = "next_cursor: none\n---\n" ..
  "tool_call_id: literal\nttl: 3 LLM rounds\n---\n" ..
  "<!-- maxa-ttl-result:start -->\nsource marker\n<!-- maxa-ttl-result:end -->"
local source = { messages = {} }
local preserved = add_read(source, "literal", "read", original, literal)
assert(preserved.content:find("next_cursor: none\ntool_call_id: literal\nttl: 3 LLM rounds\n---\n",1,true) == 1)
assert(ttl.apply_action(source, "literal", "defer", 5))
assert(ttl.apply_action(source, "literal", "persist"))
assert(preserved.content == literal, "defer/persist removed source bytes")

-- Legacy footers are recognized only as the exact appended suffix.
local legacy_body = "body\n<!-- maxa-ttl-result:start -->\nsource marker\n<!-- maxa-ttl-result:end -->"
local legacy = { role = "tool", tools = { call_id = "old-footer" }, content = legacy_body ..
  "\n\n<!-- maxa-ttl-result:start -->\nTTL result: tool_call_id=old-footer expires in 3 LLM round(s).\n" ..
  "If the default expiry is not OK, immediately call keep with that tool_call_id and action=discard|defer|keep|persist.\n" ..
  "<!-- maxa-ttl-result:end -->", _meta = { ttl_result = { call_id = "old-footer", ttl = 3, policy = "expire", enabled = true } } }
assert(ttl.apply_action({messages={legacy}}, "old-footer", "keep"))
assert(legacy.content == legacy_body, "legacy footer removal touched source marker")

print("ttl_repeat_read_spec: OK")
