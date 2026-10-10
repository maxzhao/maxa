-- Run: nvim --headless -u NONE -l lua/maxa/interactions/chat/tools/builtin/tests/search_spec.lua
vim.opt.runtimepath:prepend(vim.fn.getcwd())
vim.opt.runtimepath:append(vim.fn.stdpath("data") .. "/lazy/plenary.nvim")
package.loaded["maxa.config"] = { constants = { USER_ROLE = "user", LLM_ROLE = "assistant" } }
local adapter = require("maxa.interactions.chat.tools.builtin.runtime.adapter")
local inventory = require("maxa.interactions.chat.tools.builtin")
local Query = require("maxa.interactions.chat.tools.builtin.runtime.search_query")
local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")
vim.fn.writefile({ "display.", "displayX", "format_tool_detail(", 'run "', "%value", "slash\\path" }, root .. "/sample.lua")
local chat = { messages = {}, opts = { cwd = root } }
local function invoke(name, params)
  local result
  adapter.invoke(inventory.resolve(name), { cwd = root, chat = chat, params = params,
    caller = { maxa_ai = { chat = chat } } }, function(value) result = value end)
  assert(vim.wait(2000, function() return result ~= nil end), "search did not complete")
  return result
end
local function text(result)
  assert(result.ok, result.error)
  return adapter.content_to_result(result.content)
end
local params = { text = { "display.", "format_tool_detail(", 'run "', "%value", "slash\\path" } }
local output = text(invoke("search", params))
assert(output:find("sample.lua:1:display.", 1, true) and not output:find("displayX", 1, true), output)
assert(output:find("sample.lua:3:format_tool_detail(", 1, true), output)
assert(output:find("sample.lua:6:slash\\path", 1, true), output)
assert(vim.deep_equal(params.text, { "display.", "format_tool_detail(", 'run "', "%value", "slash\\path" }), "preparation mutated caller input")
assert(text(invoke("search", { regex = { "^display\\.$", "^format_tool_detail\\($" } })):find("sample.lua:3:", 1, true))
assert(text(invoke("search", { text = "DISPLAY.", case = "insensitive", output = "files" })) == "sample.lua")
assert(text(invoke("glob", { patterns = "*.lua" })) == "sample.lua", "glob must retain patterns")
for _, bad in ipairs({
  {}, {text="x",regex="x"}, {patterns="x"}, {text="x",literal=true}, {text="x",unknown=true},
  {text=""}, {text={}}, {text={"x",""}}, {regex=vim.NIL}, {regex={1}},
}) do assert(not invoke("search", bad).ok, vim.inspect(bad)) end
assert(not invoke("search", {regex="format_tool_detail%("}).ok)
local args = vim.json.encode(params)
assert(text(invoke("run", {title="wrapped search",scope="tool",command="search",args=args})) == output)
local batch = require("maxa.interactions.chat.tools.builtin.tests.native_batch_fixture").execute(chat, {title="search batch",runs={
  {scope="tool",command="search",args=args},
}})
assert(vim.wait(2000, function() return batch.closed end))
assert(batch.summary.status == "completed" and batch.members[1].text == output)
local function filter(query, candidates)
  local result, failure, complete
  Query.filter(query, candidates, function(value, err) result, failure, complete = value, err, true end)
  assert(vim.wait(2000, function() return complete end))
  return result, failure
end
local matched = assert(filter({mode="regex",values={"^late_match$"}}, {"no", "still_no", "late_match"}))
assert(matched[3] and not matched[1], "filter must not pre-limit candidates")
local missing, failure = filter({mode="regex",values={"("}}, {})
assert(not missing and failure:find("regex:",1,true), "empty candidates must still validate regex")
vim.fn.delete(root, "rf")
print("SEARCH_TEXT_REGEX_SPEC_OK")
