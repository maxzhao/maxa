local M = {}
local GROUP = "maxa.ai.completion.cmp"

---@return boolean
function M.setup()
  local config = require("maxa.config")
  local cmp = require("cmp")
  local group = vim.api.nvim_create_augroup(GROUP, { clear = true })
  vim.api.nvim_create_autocmd("FileType", {
    group = group,
    pattern = "maxa_ai",
    callback = function()
      local completion = "maxa.providers.completion.cmp"
      cmp.register_source("maxa_ai_slash_commands", require(completion .. ".slash_commands").new(config))
      cmp.register_source("maxa_ai_tools", require(completion .. ".tools").new(config))
      cmp.register_source("maxa_ai_variables", require(completion .. ".variables").new())
      cmp.setup.filetype("maxa_ai", {
        enabled = true,
        sources = vim.list_extend({
          { name = "maxa_ai_slash_commands" },
          { name = "maxa_ai_tools" },
          { name = "maxa_ai_variables" },
        }, cmp.get_config().sources),
      })
      return true
    end,
  })
  return true
end

function M.reset_setup()
  pcall(vim.api.nvim_del_augroup_by_name, GROUP)
end

return M
