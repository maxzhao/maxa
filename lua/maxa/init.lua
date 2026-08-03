-- filepath: lua/maxa/init.lua
--- maxa — single entrypoint (standard LazyVim plugin setup pattern).
---
--- `require("maxa").setup(opts)` is the ONLY boot entry. `opts` is merged over the
--- internal, user-overridable defaults below (`M.defaults`); consumers read the effective
--- config from `M.config`. `lua/plugins/maxa.lua` hands LazyVim the `opts`/`config` wiring
--- so end users can override via `{ "maxa", opts = { ... } }` without touching runtime.
local M = {}

M.name = "maxa"

---# Internal, overridable default configuration.
--- These are maxa's own defaults (kept inside the runtime, not in `lua/config`); users
--- override them by passing `opts` to setup. LazyVim merges multiple `opts` automatically.
M.defaults = {
  -- Initial provider / model used by the Chat view (phase-0 mock/echo).
  provider = "mock",
  model = "mock-model",
  -- Leader-prefixed command mapping surfaced by lazy `keys` (see lua/plugins/maxa.lua).
  keymaps = {
    chat = "<leader>mx",
  },
}

--- Effective configuration after `setup(opts)` (defaults overlaid with user opts).
M.config = {}

--- Setup/entry point. Merges `opts` over internal defaults, then assembles the runtime
--- and the Neovim host (making host view defaults follow the resolved config).
---@param opts? table user configuration merged over M.defaults
---@return table effective config
function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", {}, M.defaults, opts or {})
  -- Assembly: load runtime + host, and propagate resolved defaults into the host view.
  require("maxa.runtime")
  local host = require("maxa.runtime.host.nvim")
  host.set_defaults({ provider = M.config.provider, model = M.config.model })
  return M.config
end

return M
