-- Run: nvim --headless -u NONE -l lua/maxa/prompts/markdown_test.lua
vim.opt.runtimepath:prepend(vim.fn.stdpath("data") .. "/lazy/plenary.nvim")
vim.opt.runtimepath:prepend(vim.fn.getcwd())

local markdown = require("maxa.prompts.markdown")

local function assert_eq(actual, expected, message)
  if not vim.deep_equal(actual, expected) then
    error(string.format("%s\nexpected=%s\nactual=%s", message, vim.inspect(expected), vim.inspect(actual)), 2)
  end
end

local prompts, err = markdown.parse_prompt([[## user

Follow these rules.

## llm

I will follow them.
]], {})
assert(err == nil, err)
assert_eq(#prompts, 2, "user/llm prompt count")
assert_eq(prompts[1].role, "user", "first role")
assert_eq(prompts[2].role, "llm", "second role")

local invalid, invalid_err = markdown.parse_prompt([[## system

Not allowed.
]], {})
assert(invalid == nil, "system role must fail")
assert(invalid_err and invalid_err:find("system", 1, true), "system error must identify role")

local unknown, unknown_err = markdown.parse_prompt([[## future

Not allowed.
]], {})
assert(unknown == nil, "unknown role must fail")
assert(unknown_err and unknown_err:find("future", 1, true), "unknown error must identify role")

local missing, missing_err = markdown.parse_prompt("No role heading", {})
assert(missing == nil, "missing role must fail")
assert(missing_err and missing_err:find("no non-empty", 1, true), "missing role error")

local ask_prompt = assert(markdown.parse_file("prompts/commands/ask.md", {}))
assert_eq(ask_prompt.name, "ask", "command name must remain ask")
assert_eq(ask_prompt.insert, "append", "ask appends to the draft")
assert_eq(assert(markdown.parse_file("prompts/commands/do_spec.md", {})).name, "do_spec", "do_spec name")
assert_eq(assert(markdown.parse_file("prompts/commands/modify_spec.md", {})).name, "modify_spec", "modify_spec name")
local files = vim.fn.glob("prompts/commands/*.md", false, true)
assert_eq(#files, 28, "active prompt inventory")
for _, path in ipairs(files) do assert(markdown.parse_file(path, {}), path) end
assert(markdown.parse_frontmatter("---\nname: example\n---\n").insert == "inline")
for _, source in ipairs({ "name: example\nopts: {}", "name: example\ninsert: invalid", "name: example\ninteraction: chat" }) do
  assert(markdown.parse_frontmatter("---\n" .. source .. "\n---\n") == nil, source)
end
local invoked = false
local item = { name = "scalar", prompts = { { role = "user", content = "${context.value} ${context.fn} ${context.missing}" } } }
markdown.resolve_placeholders(item, { value = false, fn = function() invoked = true end })
assert(not invoked, "placeholder functions must never execute")
assert_eq(item.prompts[1].content, "false ${context.fn} ${context.missing}", "non-scalar placeholders remain literal")

print("MARKDOWN_PROMPT_ROLES_OK")
