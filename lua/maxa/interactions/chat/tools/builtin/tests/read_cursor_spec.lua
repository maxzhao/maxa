-- Run: nvim --headless -u NONE -l lua/maxa/interactions/chat/tools/builtin/tests/read_cursor_spec.lua
package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path
local plenary = vim.fn.stdpath("data") .. "/lazy/plenary.nvim"
if vim.fn.isdirectory(plenary) == 1 then
  vim.opt.runtimepath:prepend(plenary)
end

local read = require("maxa.interactions.chat.tools.builtin.tools.builtin_read")
local adapter = require("maxa.interactions.chat.tools.builtin.runtime.adapter")
local path = vim.fn.tempname()
local file = assert(vim.uv.fs_open(path, "w", 384))
local original = "first\r\n" .. string.rep("é", 10500) .. "\r\nlast\n"
assert(vim.uv.fs_write(file, original, 0) == #original)
assert(vim.uv.fs_close(file))

local function call(params)
  params.path = path
  local result
  adapter.invoke(read, { params = params }, function(value)
    result = value
  end)
  assert(result, "read did not complete")
  return result
end

local function chunk(params)
  local result = call(params)
  assert(result.ok, result.error)
  local text = adapter.content_to_result(result.content)
  assert(#text <= 20000, "read exceeded 20k total bytes")
  local cursor, start = text:match("^next_cursor: ([^\n]+)\n%-%-%-\n()")
  assert(cursor and start, "missing unambiguous result header")
  return cursor, text:sub(start)
end

local pieces, cursor = {}, nil
for _ = 1, 8 do
  local next_cursor, body = chunk({ result_policy = "temporary", cursor = cursor })
  pieces[#pieces + 1] = body
  cursor = next_cursor ~= "none" and next_cursor or nil
  if not cursor then
    break
  end
end
assert(cursor == nil and table.concat(pieces) == original, "cursor lost, duplicated, or changed source bytes")
assert(#pieces >= 2, "overlong line was not continued")

local _, anchored = chunk({ result_policy = "temporary", start_line = 2, end_line = -1 })
assert(anchored:sub(1, 2) == "é", "line anchor did not locate the second line")
local _, bounded = chunk({ result_policy = "keep", start_line = 1, end_line = 1 })
assert(bounded == "first\r\n", "positive end_line must bound ordinary reads")
local ranged_cursor, ranged = chunk({ result_policy = "keep", start_line = 1, end_line = 2 })
assert(ranged_cursor ~= "none", "long bounded range should continue")
local final_cursor, remainder = chunk({ result_policy = "keep", cursor = ranged_cursor })
assert(final_cursor == "none" and ranged .. remainder == original:sub(1, -6), "cursor escaped the requested end_line")
local omitted_cursor, omitted = chunk({ result_policy = "keep", start_line = 2 })
local explicit_cursor, explicit = chunk({ result_policy = "keep", start_line = 2, end_line = -1 })
assert(omitted == explicit and omitted_cursor == explicit_cursor, "omitted and -1 end_line differ")

local function rejects(params, expected)
  local result = call(params)
  assert(not result.ok and result.error:find(expected, 1, true), vim.inspect(result))
end
rejects({ result_policy = "temporary", end_line = 2 }, "temporary reads support only")
rejects({ force = true }, "force=true is no longer supported")
rejects({ cursor = "bad" }, "Invalid cursor")
rejects({ cursor = omitted_cursor, start_line = 2 }, "cursor cannot be combined")
local changed = assert(vim.uv.fs_open(path, "a", 384))
assert(vim.uv.fs_write(changed, "changed", -1))
assert(vim.uv.fs_close(changed))
rejects({ result_policy = "keep", cursor = omitted_cursor }, "Cursor does not match")
assert(vim.uv.fs_unlink(path))

-- The canonical TTL head is included in the existing 20k result bound.
local chat = { messages = {} }
local ctx = { chat = chat, tool_call_id = "call-long-ttl" }
local output
read.respond_content(ctx, adapter.Result.new(function(value) output = value end),
  {result_policy="temporary"}, path, original, path)
local text = adapter.content_to_result(output.content)
local msg = {role="tool",tools={call_id=ctx.tool_call_id},content=text}
chat.messages = {msg}
local ttl = require("maxa.interactions.chat.tools.builtin.runtime.ttl_result")
assert(ttl.attach_to_tool_result(chat,msg,ctx.tool_call_id,{ttl=3,cleanup="content"}))
assert(#msg.content <= 20000, "TTL head exceeded canonical read limit")
local body = msg.content:match("\n%-%-%-\n(.*)")
assert(body == text:match("\n%-%-%-\n(.*)"), "TTL changed chunk bytes")
assert(ttl.apply_action(chat,ctx.tool_call_id,"keep"))
assert(msg.content == text, "keep changed cursor/header/source bytes")
print("read_cursor_spec: OK")
