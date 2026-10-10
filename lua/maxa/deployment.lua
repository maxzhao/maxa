-- Legacy two-phase entrypoint for out-of-tree callers; ai.lua uses merged Lazy opts.
local M = {}

local runtime_config = require("maxa.config")
local mcp_config = require("maxa.mcphub.native_servers.config")
local default_adapter = require("maxa.session.default_adapter")

function M.setup_early(deployment)
  -- This must happen before VimEnter, not in the Lazy config callback.
  pcall(function()
    require("maxa.session.nvim_restart_resume").setup()
  end)
  require("maxa.prompts.commands").setup()
  require("maxa.project.drafts").setup_commands()

  runtime_config.configure_early(deployment)
  require("maxa.session.buffer_translate").setup(runtime_config.runtime().translate)
  mcp_config.configure(runtime_config.runtime().presets)
  local default_cfg = mcp_config.get_default("chat")
  return {
    default = default_adapter.get_initial_config(default_cfg),
    title = mcp_config.get_internal_adapter("title") or default_cfg,
  }
end

function M.configure(opts, initial)
  opts.maxa_lifecycle = vim.tbl_deep_extend("force", opts.maxa_lifecycle or {}, {
    default_adapter = initial.default.adapter,
    default_model = initial.default.model,
  })
  runtime_config.configure_early(opts.maxa)
  mcp_config.configure(runtime_config.runtime().presets)

  local configured_default = default_adapter.get_initial_config(mcp_config.get_default("chat"))
  if vim.deep_equal(opts.interactions.chat.adapter, {
    name = initial.default.adapter,
    model = initial.default.model,
  }) then
    opts.interactions.chat.adapter = { name = configured_default.adapter, model = configured_default.model }
  end
  opts.maxa_lifecycle.default_adapter = configured_default.adapter
  opts.maxa_lifecycle.default_model = configured_default.model

  local title_opts = opts.extensions
    and opts.extensions.history
    and opts.extensions.history.opts
    and opts.extensions.history.opts.title_generation_opts
  if
    title_opts
    and vim.deep_equal(title_opts, {
      adapter = initial.title.adapter,
      model = initial.title.model,
      thinking_mode = initial.title.thinking_mode,
    })
  then
    local updated_title = mcp_config.get_internal_adapter("title")
    opts.extensions.history.opts.title_generation_opts = {
      adapter = updated_title.adapter,
      model = updated_title.model,
      thinking_mode = updated_title.thinking_mode,
    }
  end

  require("maxa.mcphub.native_servers.genai.default_adapter").refresh_loaded(runtime_config.runtime().genai)
  require("maxa.session.buffer_translate").setup(runtime_config.runtime().translate)
end

return M
