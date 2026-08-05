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
---     runtime (lua/maxa/init.lua `M.defaults`), so overriding users replace this file,
---     not internals.
---
--- 配置遵循 LazyVim 规则：所有默认值在 `lua/maxa/init.lua` 的 `M.defaults` 统一管理
--- （注释即文档）；本项目（开发母仓库）在这里通过 `opts` 覆盖 —— 声明真实
--- provider 验证配置（deepseek，凭据只按名引用 `DEEPSEEK_TEST_KEY`，值从根目录
--- `.env` 注入，不落盘）。目标项目在各自 `lua/plugins/maxa.lua` 中以同样方式覆盖。
-- Derive this repo's root from this file's own absolute path:
--   debug.getinfo(1, "S").source == "@<repo>/lua/plugins/maxa.lua"
local src = debug.getinfo(1, "S") and debug.getinfo(1, "S").source or ""
local repo_root = src:match("^@(.+)/lua/plugins/maxa%.lua$") or vim.fn.getcwd()
return {
  {
    name = "maxa",
    dir = repo_root .. "/lua/maxa", -- minimal source carrier; runtime modules live here
    lazy = true,
    cmd = { "MaxaChat", "MaxaStop", "MaxaClose", "MaxaClear", "MaxaProvider", "MaxaModel", "MaxaDemo" },
    keys = { {
      "<leader>mx",
      "<cmd>MaxaChat<cr>",
      desc = "maxa: open chat",
    } },
    dependencies = {
      "nvim-lua/plenary.nvim",
      "folke/snacks.nvim",
    },
    --- Single standard entry: default values live inside lua/maxa/init.lua (M.defaults)
    --- and are overridable by the user via `opts` here or another `{ "maxa", opts = {...} }`.
    opts = {
      --- 开发母仓库的真实 provider 验证配置（阶段 1/2 验证资产）。
      --- 默认 provider 切换为 deepseek-chat；`DEEPSEEK_TEST_KEY` 由 setup 的
      --- dev-asset 注入从 <repo-root>/.env 读取，配置树中无凭据字面量。
      provider = {
        default = "deepseek-chat",
        definitions = {
          ["deepseek-chat"] = {
            protocol = "openai_chat",
            base_url = "https://api.deepseek.com",
            api_key_env = "DEEPSEEK_TEST_KEY",
            model = "deepseek-v4-flash",
            capabilities = { vision = false, tools = true, reasoning = true },
            request = { timeout_ms = 60000, connect_timeout_ms = 10000, retries = 0 },
          },
          ["deepseek-responses"] = {
            protocol = "openai_responses",
            base_url = "https://api.deepseek.com",
            api_key_env = "DEEPSEEK_TEST_KEY",
            model = "deepseek-v4-flash",
            capabilities = { vision = false, tools = true, reasoning = true },
            request = { timeout_ms = 60000, connect_timeout_ms = 10000, retries = 0 },
          },
          ["deepseek-anthropic"] = {
            protocol = "anthropic_messages",
            base_url = "https://api.deepseek.com/anthropic",
            api_key_env = "DEEPSEEK_TEST_KEY",
            model = "deepseek-v4-flash",
            capabilities = { vision = false, tools = true, reasoning = true },
            request = { timeout_ms = 60000, connect_timeout_ms = 10000, retries = 0 },
          },
        },
      },
    },
    config = function(_, opts)
      require("maxa").setup(opts)
    end,
  },
}
