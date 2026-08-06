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
  ---         context_window = 128000, -- 可选：上下文窗口（tokens）；缺省 128000，用于 context-stop 用量估算
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
    --- 打开 Chat 视图时是否直接进入 insert 模式（默认 false = 保持 normal；
    --- host View:open 的 `startinsert` 按此条件化）。
    start_in_insert = false,
    --- spinner 显示延迟（ms；0 = 立即显示；默认 300 与 status spine 默认一致）。
    spinner_delay = 300,
  },
  --- 会话历史与重启恢复（阶段 4 消费；默认关闭，显式开启后才装配服务）。
  ---   * enabled：总开关；false 时不做任何 history 服务构造 / auto-save
  ---     订阅 / continue_last 行为（:MaxaSave / :MaxaHistory 命令仍存在，
  ---     调用时提示 history 未启用）。
  ---   * auto_save：response.completed / tool_batch.finished /
  ---     chat.soft_stop_completed 及视图关闭（确定性显式保存）时自动保存
  ---     当前会话；unsavable（scratch）会话一律跳过。
  ---   * continue_last：`:MaxaChat` 打开新默认视图且无既有会话时，自动恢复
  ---     最近一次保存的会话（save -> close -> reopen 闭环）。
  ---   * title_provider：标题生成策略 —— "auto"（LLM 生成，失败回退首条
  ---     user 消息）| "first_user"（首条 user 消息截断）| "none"（不生成）。
  ---   * expiration_days：过期清理天数；0 = 永不过期（启动时清理）。
  ---   * title_generation_opts：标题生成选项 —— refresh_every_n_prompts
  ---     （每 N 次提示刷新一次；0 = 仅首次生成）、max_refreshes（刷新次数
  ---     上限）、format_title（nil | 标题后处理函数，如：
  ---       format_title = function(title) return title:sub(1, 60) end）。
  history = {
    enabled = false,
    auto_save = true,
    continue_last = false,
    title_provider = "auto", -- "auto" | "first_user" | "none"
    expiration_days = 0,
    title_generation_opts = { refresh_every_n_prompts = 0, max_refreshes = 3, format_title = nil },
  },
  --- 编排器默认（阶段 2 消费；host 创建 orchestrator 时经 config.effective
  --- 注入本块，orchestrator 内部与 ORCHESTRATOR_DEFAULTS 深合并）。
  ---   * tool_concurrency：工具批并行度（当前执行器仍顺序运行，>1 暂不激活
  ---     并行；保留给未来并行 barrier）。
  ---   * watchdog：请求看守 —— enabled 总开关（默认关）；timeout_ms 无进展
  ---     观察窗口；max_retries 有界重试上限（耗尽 = 单次终端 failed）。
  ---   * context_stop：上下文上限自动 soft-stop 总开关（:MaxaContextStop 的
  ---     配置级默认；运行时仍可手动 arm/disarm）。
  --- 参考样例（写入会生效；默认值如上，无需显式声明）：
  ---   orchestrator = {
  ---     tool_concurrency = 1,
  ---     watchdog = { enabled = true, timeout_ms = 180000, max_retries = 3 },
  ---     context_stop = { enabled = false },
  ---   }
  orchestrator = {
    tool_concurrency = 1,
    watchdog = {
      enabled = false,
      timeout_ms = 180000,
      max_retries = 3,
    },
    context_stop = {
      enabled = false,
    },
  },
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
  --- 全局状态投影配置（阶段5 W2/W5 消费；host set_defaults 保存，status 服务
  --- 装配点由未来的主会话 status wiring 消费；未装配时仅保存默认，不报错）：
  ---   * lualine：lualine 组件开关 —— enabled 总开关，show_spinner/show_usage
  ---     控制 busy spinner 与 token usage 是否进入投影文本。
  ---   * billing：可选的配额/计费投影 —— enabled 总开关；provider 仅按名引用
  ---     函数或模块名（运行时解析失败投影为 unavailable，绝不报错）。样例
  ---     （函数返回 `{ tokens=..., cost_usd=..., currency="USD" }` 形状）：
  ---       status = { billing = {
  ---         enabled = true,
  ---         provider = function(usage) return { tokens = usage and usage.total_tokens, cost_usd = nil } end,
  ---       } }
  status = {
    lualine = { enabled = true, show_spinner = true, show_usage = true },
    billing = { enabled = false, provider = nil },
  },
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
    -- W4-B: Phase-4 history service (nil when history disabled / no project
    -- root); history_error carries the typed failure when construction could
    -- not run (assembly itself is never fatal).
    history = asm.history,
    history_error = asm.history_error,
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
  local host_opts = {
    provider = M.config.provider and M.config.provider.default or "mock",
    model = M.config.model,
    show_reasoning = ui.show_reasoning,
    layout = ui.layout,
    -- W5: Chat 视图打开模式 + spinner/status 配置（host set_defaults 消费；
    -- status 服务未装配时仅保存默认，不报错）。
    start_in_insert = ui.start_in_insert,
    spinner_delay = ui.spinner_delay,
    status = M.config.status,
    -- W1: the assembled tool registry becomes the host default so default
    -- views (e.g. `:MaxaChat` -> `_get_default`) see MCP/skill tools.
    tool_registry = M.assembly.tool_registry,
  }
  -- W4-B: history wiring is opt-in — the host receives the assembled service
  -- ONLY when history.enabled and the assembly constructed one (project root
  -- present). When disabled, the host stays history-free (commands exist but
  -- notify; no auto-save subscriptions; no continue_last behavior).
  if M.config.history and M.config.history.enabled and M.assembly.history then
    host_opts.history = M.assembly.history
    host_opts.history_config = M.config.history
  end
  -- W6 (phase-5): status service (spine) + Action/Command registry wiring.
  -- Non-blocking: a construction failure is recorded and setup continues so
  -- the Chat host stays usable (same semantics as MCP/skills/history).
  -- Status service: immutable spine reducer over the shared event bus; the
  -- host lualine component reads it through host/nvim/status.lua set_spine.
  local status_mod = require("maxa.runtime.status")
  local ok_svc, status_service = pcall(status_mod.new, {
    events = require("maxa.runtime.events"),
    config = M.config,
  })
  if ok_svc and status_service then
    local ok_start, start_err = pcall(status_service.start, status_service)
    if ok_start then
      host_opts.status_service = status_service
    elseif not M.assembly.errors then
      M.assembly.errors = {}
    end
    if not ok_start then
      M.assembly.errors[#M.assembly.errors + 1] = { what = "status", err = start_err }
    end
  end
  -- Action/Command registry: fresh registry + built-in operation families.
  local actions_mod = require("maxa.runtime.actions")
  local registry = actions_mod.default or actions_mod.new()
  local ok_reg, reg_err = pcall(function()
    require("maxa.runtime.actions.builtin").register_all(registry)
  end)
  if ok_reg then
    host_opts.actions_registry = registry
  elseif M.assembly.errors then
    M.assembly.errors[#M.assembly.errors + 1] = { what = "actions", err = reg_err }
  end
  host.set_defaults(host_opts)
  -- W6 (phase-5): lualine auto-mount (LazyVim ecosystem). When
  -- `status.lualine.enabled` and lualine is loaded with `get_config()`, the
  -- maxa status component (read-only spine projection) is inserted at the head
  -- of `lualine_x` and the statusline is refreshed. Absent lualine or an
  -- unreadable config is silently skipped — the component stays available for
  -- manual mounting via `require("maxa.runtime.host.nvim.status").lualine_component()`.
  local lualine_cfg = M.config.status and M.config.status.lualine
  if lualine_cfg and lualine_cfg.enabled ~= false then
    pcall(function()
      local lualine = require("lualine")
      if type(lualine.get_config) == "function" then
        local lc = lualine.get_config()
        lc.sections = lc.sections or {}
        lc.sections.lualine_x = lc.sections.lualine_x or {}
        local already = false
        for _, c in ipairs(lc.sections.lualine_x) do
          if type(c) == "table" and c.name == "maxa_status" then
            already = true
            break
          end
        end
        if not already then
          local comp = require("maxa.runtime.host.nvim.status").lualine_component()
          table.insert(lc.sections.lualine_x, 1, { comp, name = "maxa_status" })
          lualine.setup(lc)
          if type(lualine.refresh) == "function" then
            lualine.refresh()
          end
        end
      end
    end)
  end
  return M.config
end
return M
