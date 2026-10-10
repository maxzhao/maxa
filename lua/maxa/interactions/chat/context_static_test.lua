-- Run: nvim --headless -u NONE -l lua/maxa/interactions/chat/context_static_test.lua
vim.opt.rtp:prepend(vim.fn.stdpath("data") .. "/lazy/plenary.nvim")
vim.opt.rtp:prepend(vim.fn.getcwd())

local original_query_get = vim.treesitter.query.get
local original_node_text = vim.treesitter.get_node_text
local nodes = { "Me", "> - 󰪴 <buf>old</buf>", "> -  <buf>diff</buf>", "> - <file>plain</file>" }
vim.treesitter.query.get = function()
  return {
    captures = { "role", "context_item" },
    iter_captures = function()
      local i = 0
      return function()
        i = i + 1
        if nodes[i] then
          return i == 1 and 1 or 2, nodes[i]
        end
      end
    end,
  }
end
vim.treesitter.get_node_text = function(node)
  return node
end

local Context = require("maxa.interactions.chat.context")
vim.treesitter.query.get = original_query_get
vim.treesitter.get_node_text = original_node_text
local chat = {
  bufnr = vim.api.nvim_create_buf(false, true),
  header_line = 1,
  chat_parser = { parse = function() return { { root = function() return {} end } } end },
}
local items = Context.new({ chat = chat }):get_from_chat()
assert(vim.deep_equal(items, { "<buf>old</buf>", "<buf>diff</buf>", "<file>plain</file>" }))
vim.api.nvim_buf_delete(chat.bufnr, { force = true })
print("CONTEXT_STATIC_OK")
