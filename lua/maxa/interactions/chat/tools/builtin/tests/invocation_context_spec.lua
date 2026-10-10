-- filepath: lua/maxa/interactions/chat/tools/builtin/tests/invocation_context_spec.lua
-- Run: nvim --headless -u NONE -l lua/maxa/interactions/chat/tools/builtin/tests/invocation_context_spec.lua
vim.opt.runtimepath:prepend(vim.fn.getcwd())
package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path

local adapter = require("maxa.interactions.chat.tools.builtin.runtime.adapter")
local root = vim.fs.root(vim.uv.cwd(), { ".maxa", ".git", ".svn", ".hg" })
local source_bufnr = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_name(source_bufnr, vim.uv.cwd() .. "/.maxa/tmp/builtin-invocation-context.md")

local chat = {
  bufnr = source_bufnr,
  buffer_context = {
    bufnr = source_bufnr,
    cwd = vim.uv.cwd(),
    project_root = root,
  },
  opts = {
    cwd = vim.uv.cwd(),
    project_root = root,
    save_id = "invocation-context-test",
  },
}
local function_call = {
  id = "fc-1",
  call_id = "call-1",
  ["function"] = { name = "load", arguments = "{}" },
}
local tool = {
  name = "load",
  function_call = function_call,
}

local context, err = adapter.invocation_from_tools({ chat = chat, tool = tool }, { target = "spec-admin" })
assert(context, tostring(err))
assert(context.chat == chat, "invocation must retain the exact Chat")
assert(context.cwd == vim.uv.cwd(), "invocation must use the Chat-owned cwd")
assert(context.project_root == root, "invocation must use the Chat-owned project root")
assert(context.save_id == "invocation-context-test", "invocation must retain save_id")
assert(context.tool_call_id == "call-1", "invocation must retain tool-call id")
assert(context.caller.maxa_ai.chat == chat, "caller must point to the exact Chat")

local missing, missing_err = adapter.invocation_from_tools({ chat = {}, tool = tool }, {})
assert(missing == nil, "adapter must reject missing Chat-owned cwd")
assert(missing_err == "exact Chat project working directory is unavailable", tostring(missing_err))

vim.api.nvim_buf_delete(source_bufnr, { force = true })
print("builtin_invocation_context_spec: OK")
