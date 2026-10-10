-- Run: nvim --headless -u NONE -l lua/maxa/providers/completion/slash_commands_test.lua
vim.opt.runtimepath:prepend(vim.fn.stdpath("data") .. "/lazy/plenary.nvim")
vim.opt.runtimepath:prepend(vim.fn.getcwd())

local api = vim.api
local completion = require("maxa.providers.completion")

local bufnr = api.nvim_create_buf(false, true)
api.nvim_set_current_buf(bufnr)
api.nvim_buf_set_lines(bufnr, 0, -1, false, { "before  after" })
local user_chat = { bufnr = bufnr }
function user_chat:add_buf_message(message, opts)
  assert(opts and opts.insert_at, "user-only Markdown slash must use invocation anchor")
  local lines = vim.split(message.content, "\n", { plain = true, trimempty = false })
  api.nvim_buf_set_text(self.bufnr, opts.insert_at.row, opts.insert_at.col, opts.insert_at.row, opts.insert_at.col, lines)
  return opts.insert_at.row + #lines
end

completion.slash_commands_execute({
  from_prompt_library = true,
  context = { slash_anchor = { row = 0, col = #"before " } },
  config = {
    insert = "inline",
    prompts = { { role = "user", content = "expanded" } },
  },
}, user_chat)
assert(api.nvim_get_current_line() == "before expanded after", "user-only Markdown expansion")

local shared_config = {
  path = "prompts/test.md",
  insert = "inline",
  prompts = { { role = "user", content = "${context.value}" } },
}
for _, value in ipairs({ "first", "second" }) do
  api.nvim_buf_set_lines(bufnr, 0, -1, false, { "" })
  completion.slash_commands_execute({
    from_prompt_library = true,
    context = { value = value, slash_anchor = { row = 0, col = 0 } },
    config = shared_config,
  }, user_chat)
  assert(api.nvim_get_current_line() == value, "placeholder resolution must use current invocation context")
end
assert(shared_config.prompts[1].content == "${context.value}", "slash execution must not mutate cached prompt config")

local ask_config = assert(require("maxa.prompts.markdown").parse_file("prompts/commands/ask.md", {}))
assert(ask_config.name == "ask", "command name must remain ask")
api.nvim_buf_set_lines(bufnr, 0, -1, false, { "油/ask芒工" })
local ask_selected = {
  label = "/" .. ask_config.name,
  from_prompt_library = true,
  context = {},
  config = ask_config,
}
local ask_prepared, ask_err = completion.prepare_slash_command(ask_selected, user_chat, bufnr, {
  start = { row = 0, col = #"油" },
  ["end"] = { row = 0, col = #"油/ask" },
})
assert(ask_prepared, ask_err)
completion.slash_commands_execute(ask_selected, user_chat)
local ask_line = table.concat(api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
assert(vim.startswith(ask_line, "油芒工\n"), "append must preserve original text before expanded content")
assert(ask_line:find("你明白我的意思吗", 1, true), "ask Markdown content must expand")

api.nvim_buf_set_lines(bufnr, 0, -1, false, { "## Me", "", "draft text" })
vim.bo[bufnr].filetype = "markdown"
local history_chat = {
  bufnr = bufnr,
  header_line = 1,
  chat_parser = vim.treesitter.get_parser(bufnr, "markdown"),
}
local captured
function history_chat:capture_editable_draft()
  return "draft text"
end
function history_chat:add_visible_history(messages, draft)
  captured = { messages = vim.deepcopy(messages), draft = draft or self:capture_editable_draft() }
  return true
end

completion.slash_commands_execute({
  from_prompt_library = true,
  context = { slash_anchor = { row = 2, col = 0 } },
  config = {
    insert = "inline",
    prompts = {
      { role = "user", content = "Follow this contract." },
      { role = "llm", content = "I will follow it." },
    },
  },
}, history_chat)
assert(captured and captured.draft == "draft text", "visible history must preserve editable draft")
assert(captured.messages[1].role == "user" and captured.messages[2].role == "llm", "visible history role order")

local blink = require("maxa.providers.completion.blink")
local source = blink.new()
local blink_items
source:get_completions({
  bufnr = bufnr,
  line = "x /no tail",
  cursor = { 1, 5 },
  bounds = { line_number = 1, start_col = 4, length = 2 },
  trigger = { character = "/" },
}, function(result)
  blink_items = result.items
end)
local now_item = vim.iter(blink_items):find(function(item)
  return item.label == "now"
end)
assert(now_item, "blink now completion")
assert(now_item.textEdit.range.start.character == 2, "blink slash range start")
assert(now_item.textEdit.range["end"].character == 5, "blink slash range end")

local unicode_items
source:get_completions({
  bufnr = bufnr,
  line = "前/no",
  cursor = { 1, #"前/no" },
  bounds = { line_number = 1, start_col = #"前/" + 1, length = 2 },
  trigger = { character = "/" },
}, function(result)
  unicode_items = result.items
end)
local unicode_now = vim.iter(unicode_items):find(function(item)
  return item.label == "now"
end)
assert(unicode_now.textEdit.range.start.character == #"前", "blink unicode byte start")
assert(unicode_now.textEdit.range["end"].character == #"前/no", "blink unicode byte end")

api.nvim_buf_set_lines(bufnr, 0, -1, false, { "x /no tail" })
local original_maxa = package.loaded["maxa"]
package.loaded["maxa"] = { buf_get_chat = function() return user_chat end }
local callback_called = false
source:execute({ bufnr = bufnr }, now_item, function() callback_called = true end)
package.loaded["maxa"] = original_maxa
local blink_line = api.nvim_get_current_line()
assert(callback_called, "blink execute callback")
assert(blink_line:sub(1, 2) == "x " and blink_line:sub(-5) == " tail", "blink must preserve same-line prefix/suffix")
assert(not blink_line:find("/no", 1, true), "blink must replace the accepted slash prefix")

local saved_slash_commands = completion.slash_commands
local dynamic_called = false
local dynamic_commands = {
  {
    label = "/pick_skill",
    detail = "dynamic test",
    type = "slash_command",
    config = {
      callback = function()
        error("stale dynamic slash command executed")
      end,
    },
  },
}
completion.slash_commands = function()
  return dynamic_commands
end
api.nvim_buf_set_lines(bufnr, 0, -1, false, { "x /psk tail" })
local dynamic_items
source:get_completions({
  bufnr = bufnr,
  line = "x /psk tail",
  cursor = { 1, 6 },
  bounds = { line_number = 1, start_col = 4, length = 3 },
  trigger = {},
}, function(result)
  dynamic_items = result.items
end)
local dynamic_item = vim.iter(dynamic_items):find(function(item)
  return item.label == "pick_skill"
end)
assert(dynamic_item, "blink must expose dynamic slash commands to fuzzy matching")
dynamic_item.data.slash_query = "/" -- A completion item may survive while the user keeps typing.
dynamic_commands = {
  {
    label = "/pick_skill",
    detail = "dynamic test",
    type = "slash_command",
    config = {
      callback = function()
        dynamic_called = true
      end,
    },
  },
}
original_maxa = package.loaded["maxa"]
package.loaded["maxa"] = {
  buf_get_chat = function()
    return user_chat
  end,
}
source:execute({ bufnr = bufnr }, dynamic_item, function() end)
package.loaded["maxa"] = original_maxa
assert(dynamic_called, "accepted fuzzy slash completion must execute the current dynamic command")
assert(api.nvim_get_current_line() == "x  tail", "fuzzy slash query must be removed at its original range")

dynamic_commands = {}
api.nvim_buf_set_lines(bufnr, 0, -1, false, { "/psk" })
local removed_prepared = completion.prepare_slash_command({ label = "/pick_skill", context = {} }, user_chat, bufnr, {
  start = { row = 0, col = 0 },
  ["end"] = { row = 0, col = 4 },
  revalidate_selection = true,
})
assert(not removed_prepared and api.nvim_get_current_line() == "/psk", "removed dynamic slash command must not execute")
completion.slash_commands = saved_slash_commands

local suffix_items
source:get_completions({
  bufnr = bufnr,
  line = "油/now芒工",
  cursor = { 1, #"油/now" },
  bounds = { line_number = 1, start_col = #"油/" + 1, length = #"now芒工" },
  trigger = { character = "/" },
}, function(result)
  suffix_items = result.items
end)
local suffix_now = vim.iter(suffix_items):find(function(item)
  return item.label == "now"
end)
assert(suffix_now.textEdit.range.start.character == #"油", "blink Chinese suffix range start")
assert(suffix_now.textEdit.range["end"].character == #"油/now", "blink range must stop at cursor")

api.nvim_buf_set_lines(bufnr, 0, -1, false, { "油/now芒工" })
original_maxa = package.loaded["maxa"]
package.loaded["maxa"] = { buf_get_chat = function() return user_chat end }
source:execute({ bufnr = bufnr }, suffix_now, function() end)
package.loaded["maxa"] = original_maxa
local suffix_line = api.nvim_get_current_line()
assert(vim.startswith(suffix_line, "油") and vim.endswith(suffix_line, "芒工"), "Chinese text around slash must be preserved")
assert(not suffix_line:find("/now", 1, true), "accepted slash token must be replaced")

local default = require("maxa.providers.completion.default.omnifunc")
api.nvim_buf_set_lines(bufnr, 0, -1, false, { "/mcp:create_native_server" })
api.nvim_win_set_cursor(0, { 1, #"/mcp:create_native_server" })
assert(default.omnifunc(1, "") == 0, "default completion must keep colon command token")

local cmp_source = require("maxa.providers.completion.cmp.slash_commands").new({})
assert(
  vim.fn.matchstr("x /mcp:create-native", cmp_source:get_keyword_pattern()) == "/mcp:create-native",
  "cmp keyword pattern must support colon and hyphen"
)

local original_slash_commands = completion.slash_commands
completion.slash_commands = function()
  return {
    {
      label = "/mcp:create_native_server",
      detail = "test",
      type = "slash_command",
      config = { callback = function() end },
    },
  }
end
local separator_items
source:get_completions({
  bufnr = bufnr,
  line = "/mcp:create_native_server",
  cursor = { 1, #"/mcp:create_native_server" },
  bounds = { line_number = 1, start_col = 6, length = 20 },
  trigger = {},
}, function(result)
  separator_items = result.items
end)
assert(#separator_items == 1, "blink must retain slash completion after colon")
assert(separator_items[1].textEdit.range.start.character == 0, "blink separator command range start")
assert(
  separator_items[1].textEdit.range["end"].character == #"/mcp:create_native_server",
  "blink separator command range end"
)

completion.slash_commands = original_slash_commands

api.nvim_buf_delete(bufnr, { force = true })
print("MARKDOWN_SLASH_EXECUTION_OK")
