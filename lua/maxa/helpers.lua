local M = {}

---Get fixed Markdown prompts for the exact buffer/project.
function M.get_prompts(bufnr)
  local context = require("maxa.utils.context").get(bufnr or vim.api.nvim_get_current_buf())
  return require("maxa.prompts.sources").get(context)
end

return M
