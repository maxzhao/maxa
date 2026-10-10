-- Run: nvim --headless -u NONE -l lua/maxa/interactions/chat/slash_commands/builtin/buffer_static_test.lua
vim.opt.rtp:prepend(vim.fn.stdpath("data") .. "/lazy/plenary.nvim")
vim.opt.rtp:prepend(vim.fn.getcwd())

local config = require("maxa.config")
local api = vim.api
local bufnr = api.nvim_create_buf(false, true)
local path = vim.fn.getcwd() .. "/buffer-static-test.lua"
api.nvim_buf_set_name(bufnr, path)
api.nvim_buf_set_lines(bufnr, 0, -1, false, { "original content" })

local messages, contexts = {}, {}
local chat = {
  add_message = function(_, message, opts)
    table.insert(messages, { message = message, opts = opts })
  end,
  context = {
    add = function(_, context)
      table.insert(contexts, context)
    end,
  },
}

assert(config.interactions.chat.slash_commands.buffer.opts.default_params == nil)
assert(config.rules == nil, "retired Rules configuration must be absent")
assert(config.interactions.chat.keymaps.buffer_sync_all == nil)
assert(config.interactions.chat.keymaps.buffer_sync_diff == nil)

local Buffer = require("maxa.interactions.chat.slash_commands.builtin.buffer")
local slash = Buffer.new({ Chat = chat, config = config.interactions.chat.slash_commands.buffer })
slash:output({ bufnr = bufnr, path = path }, { silent = true })
assert(#messages == 1 and #contexts == 1, "buffer attachment should be added once")
assert(messages[1].message.content:find("original content", 1, true), "buffer content should be attached")
assert(messages[1].opts.visible == false, "attachment message should remain hidden")
assert(contexts[1].bufnr == bufnr and contexts[1].id == messages[1].opts.context.id)
assert(not contexts[1].opts.sync_all and not contexts[1].opts.sync_diff, "context must not enable syncing")

api.nvim_buf_set_lines(bufnr, 0, -1, false, { "modified content" })
assert(#messages == 1, "editing an attached buffer must not create a new message")
api.nvim_buf_delete(bufnr, { force = true })
print("BUFFER_STATIC_OK")
