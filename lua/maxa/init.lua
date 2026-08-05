-- filepath: lua/maxa/init.lua
--- maxa — single entrypoint (standard LazyVim plugin setup pattern).
---
--- `require("maxa").setup(opts)` is the ONLY boot entry. Configuration follows
--- LazyVim rules (reference: CodeCompanion `setup(opts)` + internal defaults,
--- see `specs/modules/bootstrap-configuration/spec.md`):
---   * ALL default values live in `M.defaults` below (comments are the config
---     documentation; there is no separate config doc file and no `.maxa/`
---     runtime configuration file);
---   * users override via LazyVim `opts` — `lua/plugins/maxa.lua` `opts` field or
---     `{ "maxa", opts = { ... } }` in their own config; LazyVim deep-merges
---     multiple `opts` automatically;
---   * `setup` merges `opts` over `M.defaults`, validates fail-closed through
---     `maxa.runtime.config`, and propagates effective defaults into the host.
---
--- Project-local *extension content* follows CodeCompanion file conventions and
--- is NOT opts parameters: `.maxa/mcp/servers.yaml` (MCP servers) and
--- `.maxa/skills/` (project Skills). The only `.maxa/` state file is
--- `.maxa/state.yaml` (runtime status, yaml format; role like SuperMax's
--- `.supermax/_meta.yaml`), read/written via `maxa.runtime.config`.
local M = {}
M.name = "maxa"
---# Internal, overridable default configuration (默认值统一管理；注释即文档)。
--- 用户在 `lua/plugins/maxa.lua` 的 `opts`（或自己的 `{ "maxa", opts = {...} }`）
--- 中覆盖以下任何字段；LazyVim 自动深合并多个 opts。
M.defaults = {
  --- 初始 provider 选择。
  --- `provider.default` 可以是内置 provider（`mock`/`echo`，位于 protocol
  --- 注册表，无需声明）或 `provider.definitions` 中声明的真实 provider id。
  --- 真实 provider 必须显式声明（协议/base_url/api_key_env/model/能力/请求参数）：
  ---   provider = {
  ---     default = "deepseek-chat",
  ---     definitions = {
  ---       ["deepseek-chat"] = {
  ---         protocol = "openai_chat",
  ---         base_url = "https://api.deepseek.com",
  ---         api_key_env = "DEEPSEEK_TEST_KEY", -- 只按名引用，禁止字面量凭据
  ---         model = "deepseek-v4-flash",
  ---         capabilities = { vision = false, tools = true, reasoning = true },
  ---         request = { timeout_ms = 60000, connect_timeout_ms = 10000, retries = 0 },
  ---       },
  ---     },
  ---   }
  --- 校验规则（fail-closed）：协议必须是四协议之一；对协议原生能力声明
  --- `false` 是冲突（openai_responses/anthropic/gemini 的 tools+reasoning、
  --- openai_chat 的 tools）；`api_key_env`/`proxy_env` 只能是环境变量名；
  --- 配置树任何位置出现字面量凭据键（api_key/token/secret/...）都会报错。
  provider = {
    default = "mock",
    definitions = {},
  },
  --- 初始模型名（host Chat 视图默认展示；provider 解析后以 provider 声明为准）。
  model = "mock-model",
  --- Chat 视图 UI 默认值（host 消费；其余内部 UI 常量保留在 host 模块内）。
  ui = {
    --- 是否展示推理（reasoning）块（与 host 现有默认一致，保持行为稳定）。
    show_reasoning = false,
    --- 布局：vertical | horizontal | float（默认 vertical = 右侧半屏分屏）。
    layout = "vertical",
  },
  --- 会话历史（阶段 4 消费；当前未启用）。
  history = {
    enabled = false,
  },
  --- 编排器默认（阶段 2 已消费；未在此声明的内部默认值保留在 orchestrator 模块）。
  orchestrator = {},
  --- 扩展类内容开关（阶段 3 消费）：项目 MCP/skill 内容文件约定见
  --- `.maxa/mcp/servers.yaml` 与 `.maxa/skills/`（mcp-skill-runtime spec）。
  skills = {},
  mcp = {},
  status = {},
  --- Leader-prefixed command mapping surfaced by lazy `keys`（见 lua/plugins/maxa.lua）。
  keymaps = {
    chat = "<leader>mx",
  },
}
--- Effective configuration after `setup(opts)` (defaults overlaid with user opts).
M.config = {}
--- W10.1 development-asset credential injection (dev-only, never persisted).
--- The runtime and any config artifact stay credential-free: provider definitions
--- only reference env vars by name (`api_key_env: DEEPSEEK_TEST_KEY`). This assembly
--- layer is the "environment asset" boundary — it reads `<repo-root>/.env` and maps
--- `DEEPSEEK_TEST_KEY` into the process env (`vim.env`) so `resolve_provider`
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
--- Setup/entry point. Merges `opts` over internal defaults (LazyVim rules),
--- validates fail-closed, then assembles the runtime and the Neovim host
--- (host view defaults follow the effective config).
---@param opts? table user configuration merged over M.defaults
---@return table effective config
function M.setup(opts)
  local config = require("maxa.runtime.config")
  local merged, cerr = config.configure(M.defaults, opts or {})
  if not merged then
    error(("[maxa] configuration failed: %s"):format(cerr and cerr.message or "unknown error"), 0)
  end
  M.config = merged
  -- W10.1: dev-asset credential injection (no-op when .env is absent).
  inject_dev_env(M_ROOT)
  -- Assembly: load runtime + host, and propagate resolved defaults into the host view.
  require("maxa.runtime")
  local host = require("maxa.runtime.host.nvim")
  local ui = M.config.ui or {}
  host.set_defaults({
    provider = M.config.provider and M.config.provider.default or "mock",
    model = M.config.model,
    show_reasoning = ui.show_reasoning,
    layout = ui.layout,
  })
  return M.config
end
return M
