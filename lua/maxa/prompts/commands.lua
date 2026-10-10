local M = {}

function M.setup()
  vim.api.nvim_create_user_command("DumpSystemPrompt", function(args)
    local ok, err = pcall(require("maxa.prompts.runtime").DumpSystemPrompt, {
      bufnr = vim.api.nvim_get_current_buf(),
      mode = args.args ~= "" and args.args or "default",
    })
    if not ok then
      vim.notify(tostring(err), vim.log.levels.ERROR)
    end
  end, {
    nargs = "?",
    complete = function()
      return { "default", "current" }
    end,
    desc = "Inspect generated default or current Chat base prompt (not the provider request)",
  })
end

return M
