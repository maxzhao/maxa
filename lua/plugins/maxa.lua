-- filepath: lua/plugins/maxa.lua
--- maxa LazyVim plugin wiring.
---
--- Deliberately uses a minimal `dir` (lua/maxa) as the lazy source carrier — NOT the whole
--- repo. lazy ignores a source-less aggregate spec (its `cmd` placeholders would not be
--- registered), so this file, which lives at <repo>/lua/plugins/maxa.lua, derives its own
--- repo root at runtime and points `dir` at that repo's `lua/maxa`. No absolute path is
--- hard-coded, so the config works from any clone location.
---
--- Loading contract handed to LazyVim:
---   - `cmd` registers lazy placeholders for :MaxaChat/:MaxaStop/... and lazy-loads the
---     runtime on first use (lazy deletes its placeholder, runs this plugin's `config`,
---     then invokes the real command that host.setup() creates). Command BODIES stay in
---     host.setup()'s create_user_command — lazy only lazily-triggers them.
---   - `dependencies` guarantees plenary/snacks (used by runtime config/protocol/host).
---   - `config` is the deliberately-thin "boot maxa" step; real defaults live in the
---     runtime (lua/maxa/runtime/...), so overriding users replace this file, not internals.

-- Derive this repo's root from this file's own absolute path:
--   debug.getinfo(1, "S").source == "@<repo>/lua/plugins/maxa.lua"
local src = debug.getinfo(1, "S") and debug.getinfo(1, "S").source or ""
local repo_root = src:match("^@(.+)/lua/plugins/maxa%.lua$") or vim.fn.getcwd()

return {
  {
    name = "maxa",
    dir = repo_root .. "/lua/maxa", -- minimal source carrier; runtime modules live here
    lazy = true,
    cmd = { "MaxaChat", "MaxaStop", "MaxaClose", "MaxaClear", "MaxaProvider", "MaxaModel" },
    keys = { {
      "<leader>mx",
      "<cmd>MaxaChat<cr>",
      desc = "maxa: open chat",
    } },
    dependencies = {
      "nvim-lua/plenary.nvim",
      "folke/snacks.nvim",
    },
    --- Single standard entry: default values live inside lua/maxa/init.lua (M.defaults) and
    --- are overridable by the user via `opts` here or another `{ "maxa", opts = {...} }`.
    opts = {},
    config = function(_, opts)
      require("maxa").setup(opts)
    end,
  },
}
