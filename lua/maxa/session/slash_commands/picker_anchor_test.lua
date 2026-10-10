-- Run: nvim --headless -u NONE -l lua/maxa/session/slash_commands/picker_anchor_test.lua
vim.opt.runtimepath:prepend(vim.fn.stdpath("data") .. "/lazy/plenary.nvim")
vim.opt.runtimepath:prepend(vim.fn.getcwd())

package.loaded["maxa.project.drafts"] = {
  project_root = function() return vim.fn.getcwd() end,
  ensure_drafts_dir = function() end,
  list_files = function()
    return { { path = ".maxa/drafts/example.md", rel_path = ".maxa/drafts/example.md", size = 1, mtime = os.time() } }
  end,
}
package.loaded["snacks.picker"] = {
  pick = function(opts)
    assert(type(opts.on_close) == "function", "picker must own cancellation cleanup")
    opts.on_close()
  end,
}

local api = vim.api
local bufnr = api.nvim_create_buf(false, true)
api.nvim_buf_set_lines(bufnr, 0, -1, false, { "draft" })
local context = { slash_anchor = { row = 0, col = 0 } }
local command = require("maxa.session.slash_commands.pick_draft").new({
  Chat = { bufnr = bufnr, add_buf_message = function() error("cancelled picker must not insert") end },
  config = {},
  context = context,
})
command:execute()
assert(context.slash_anchor_extmark == nil, "picker cancellation must release invocation anchor")

api.nvim_buf_delete(bufnr, { force = true })
print("PICKER_SLASH_ANCHOR_OK")
