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
  -- Initial provider / model used by the Chat view (mock/echo by default; real
  -- providers are selected per-view via :MaxaProvider / View:set_provider).
  provider = "mock",
  model = "mock-model",
  -- Leader-prefixed command mapping surfaced by lazy `keys` (see lua/plugins/maxa.lua).
  keymaps = {
    chat = "<leader>mx",
  },
}

--- Effective configuration after `setup(opts)` (defaults overlaid with user opts).
M.config = {}

--- W10.1 development-asset credential injection (dev-only, never persisted).
--- The runtime and `.maxa/runtime.yaml` stay credential-free: the config schema only
--- references env vars by name (`api_key_env: DEEPSEEK_TEST_KEY`). This assembly
--- layer is the "environment asset" boundary — it reads `<repo-root>/.env` and maps
--- `DEEPSEEK_TEST_KEY` into the process env (`vim.env`) so `config.resolve_provider`
--- can resolve it at call time. The value is never echoed, logged, or stored on
--- `M.config` / any artifact.
--- Target projects replace this block with their own credential source at this same
--- assembly boundary (e.g. a platform secret store); nothing below assumes `.env`.
---@param root string repo/project root directory
local function inject_dev_env(root)
  local f = io.open(root .. "/.env", "rb")
  if not f then
    return
  end
  local body = f:read("*a")
  f:close()
  for line in body:gmatch("[^\r\n]+") do
    local value = line:match("^%s*DEEPSEEK_TEST_KEY%s*=%s*(.-)%s*$")
    if value and value ~= "" then
      vim.env.DEEPSEEK_TEST_KEY = value
      return
    end
  end
end

---@private Resolve this repository's root from this module's own path:
---   debug.getinfo(1, "S").source == "@<repo>/lua/maxa/init.lua"
--- (same pattern as lua/plugins/maxa.lua; no hard-coded absolute path).
local src = debug.getinfo(1, "S") and debug.getinfo(1, "S").source or ""
local M_ROOT = src:match("^@(.+)/lua/maxa/init%.lua$") or vim.fn.getcwd()

--- Setup/entry point. Merges `opts` over internal defaults, then assembles the runtime
--- and the Neovim host (making host view defaults follow the resolved config).
---@param opts? table user configuration merged over M.defaults
---@return table effective config
function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", {}, M.defaults, opts or {})
  -- W10.1: dev-asset credential injection (no-op when .env is absent).
  inject_dev_env(M_ROOT)
  -- Assembly: load runtime + host, and propagate resolved defaults into the host view.
  require("maxa.runtime")
  local host = require("maxa.runtime.host.nvim")
  -- chat-ui config (phase 1.5 subpackage 3.6): the target project's
  -- `.maxa/runtime.yaml` `ui` block tunes host view defaults. The snapshot is
  -- a frozen proxy; `unfreeze` recovers the real tree (LuaJIT pairs ignores
  -- __pairs, so direct indexing is used on the unfrozen view). A missing file
  -- or absent ui block leaves host defaults untouched.
  local ui_defaults = {}
  local cfg = require("maxa.runtime.config")
  local snap = cfg.load(M_ROOT, { resolve_root = false })
  local raw = snap and cfg.unfreeze(snap._view)
  if raw and raw.ui then
    if raw.ui.show_reasoning ~= nil then
      ui_defaults.show_reasoning = raw.ui.show_reasoning
    end
    if raw.ui.layout ~= nil then
      ui_defaults.layout = raw.ui.layout
    end
  end
  host.set_defaults({
    provider = M.config.provider,
    model = M.config.model,
    show_reasoning = ui_defaults.show_reasoning,
    layout = ui_defaults.layout,
  })
  return M.config
end

return M
