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
  --- Skill 子系统（阶段 3/W7 消费；mcp-skill-runtime spec）：
  ---   * enabled：总开关；false 时运行时装配不做任何 Skill 发现/注册。
  ---   * roots：发现根开关，与 skills.discover 的三类根一一对应 ——
  ---     bundled（rtp `skills/`，如本仓库自带 bundled 技能）、config
  ---     （`stdpath("config")/skills` 用户级全局）、project
  ---     （项目 `.maxa/skills/`，优先级最高）。任一为 false 则装配时
  ---     跳过对应根（默认全开）。
  skills = {
    enabled = true,
    roots = { bundled = true, config = true, project = true },
  },
  --- MCP 子系统（阶段 3/W7 消费；mcp-skill-runtime spec）：
  ---   * enabled：总开关；false 时运行时装配不加载服务器配置。
  ---   * servers_file：项目相对路径的 MCP 服务器声明文件（默认
  ---     `.maxa/mcp/servers.yaml`；缺文件 = 空配置非错误；`${PROJECT_ROOT}`
  ---     与 `${ENV_VAR}` 替换由 mcp.config.load 处理）。`.supermax/` 永不作为来源。
  mcp = {
    enabled = true,
    servers_file = ".maxa/mcp/servers.yaml",
  },
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
--- W7/W1 extension-content assembly: real-path runtime assembly through
--- `maxa.runtime.assemble` — a shared tool registry, the project
--- `.maxa/mcp/servers.yaml` (respecting `mcp.enabled` / `mcp.servers_file`),
--- and skill discovery/loading (respecting `skills.enabled` / `skills.roots`).
--- Missing servers file = empty configuration, NEVER an error; `.supermax/` is
--- never consulted as a source. A structural servers-file violation is a
--- fail-closed typed error recorded on `M.assembly.mcp_error` (setup continues
--- so the Chat host stays usable; the error is observable by consumers, e.g. a
--- status projection). The assembly record is extended with
--- `tool_registry` / `mcp_registry` / `skills_state` / `teardown`.
---@param config_mod table maxa.runtime.config
local function assemble_extensions(config_mod)
  local cfg = M.config
  local asm = require("maxa.runtime").assemble(cfg, {})
  M.assembly = {
    skills = {
      enabled = not (cfg.skills and cfg.skills.enabled == false),
      roots = (cfg.skills and cfg.skills.roots) or {},
    },
    tool_registry = asm.tool_registry,
    mcp = asm.mcp_config, -- loaded servers config (existing shape; empty config when missing file)
    mcp_registry = asm.mcp_registry, -- additive: live mcp server registry
    mcp_error = asm.mcp_error,
    skills_state = asm.skills_state,
    errors = asm.errors,
    teardown = asm.teardown,
  }
end
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
  -- W7: project extension content (`.maxa/mcp/servers.yaml` + skill switches).
  assemble_extensions(config)
  local host = require("maxa.runtime.host.nvim")
  local ui = M.config.ui or {}
  host.set_defaults({
    provider = M.config.provider and M.config.provider.default or "mock",
    model = M.config.model,
    show_reasoning = ui.show_reasoning,
    layout = ui.layout,
    -- W1: the assembled tool registry becomes the host default so default
    -- views (e.g. `:MaxaChat` -> `_get_default`) see MCP/skill tools.
    tool_registry = M.assembly.tool_registry,
  })
  return M.config
end
return M
