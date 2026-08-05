-- filepath: lua/maxa/runtime/config/init.lua
--- maxa runtime configuration：LazyVim opts 合并 + fail-closed 校验 + 项目运行状态。
---
--- 配置架构（遵循 LazyVim 插件惯例；参考 CodeCompanion `setup(opts)` + 内部
--- defaults 深合并模型，见 `specs/modules/bootstrap-configuration/spec.md`）：
---   * 默认值统一在 `lua/maxa/init.lua` 的 `M.defaults` 管理（注释即文档）；
---   * 用户配置 = LazyVim `opts`（`lua/plugins/maxa.lua` 或 `{ "maxa", opts = {...} }`）；
---   * `configure(defaults, opts)` 深合并 + 校验，产出有效配置树（`M.effective`）；
---   * 扩展类内容遵循 CodeCompanion 文件约定（不是 opts 参数）：项目 MCP 声明
---     `.maxa/mcp/servers.yaml`、项目 Skills `.maxa/skills/`（见
---     `specs/modules/mcp-skill-runtime/spec.md`）。
---
--- 项目运行状态（非配置层）是 `<project-root>/.maxa/state.yaml`（正式名，yaml 格式；
--- 角色类似 SuperMax `.supermax/_meta.yaml`），由 `find_project_root` / `load_state` /
--- `save_state` 读写；缺失视为未初始化，不构成配置错误。凭据永远只按名引用
--- （`api_key_env`），字面量 secret 值被拒绝。
---
--- 上游对齐（只读，不复制）：`codecompanion/config.lua`（defaults、深合并、
--- 配置访问器）；`lua/plugins/ai.lua` `make_llm_gateway_adapter`（name/protocol/
--- base_url 校验、trailing-slash 归一化）；目标契约见
--- `specs/modules/supermax-configuration/spec.md` 与
--- `specs/modules/provider-contract/spec.md`。
---
--- Dependencies: `maxa.runtime.schema`（typed errors），`maxa.runtime.config.yaml`
--- （state.yaml 解码）。Never loads `codecompanion.*`/`mcphub.*`/`lua/util/hooks/*`.
----------------------------------------------------------------------------------------
local schema = require("maxa.runtime.schema")
local yaml = require("maxa.runtime.config.yaml")
local M = {}
M.name = "config"

--- 项目运行状态文件（正式名）：`.maxa/` 下唯一的状态文件（非配置层）。
M.STATE_YAML = ".maxa/state.yaml"
--- 项目目录标记：`.maxa/` 目录本身用于定位项目根（状态文件所在）。
M.STATE_DIR = ".maxa"

--- 允许的核心顶层键（LazyVim opts 顶层；`extensions` 是唯一开放键）。
M.CORE_KEYS = {
  "provider",
  "model",
  "ui",
  "history",
  "orchestrator",
  "skills",
  "mcp",
  "status",
  "keymaps",
  "extensions",
}

--- The four protocol enum values (config must never alias one to another: a provider
--- named `gemini` still has to declare `protocol: gemini` to get native behavior).
M.PROTOCOLS = { "openai_chat", "openai_responses", "anthropic_messages", "gemini" }
--- Protocol-native capability channels (provider-contract spec matrix): channels the
--- protocol provides as a first-class contract regardless of model. Declaring `false`
--- for a native channel is a configuration conflict ("capability 与协议缺省冲突").
--- Declaring `true` for a non-native channel (e.g. openai_chat `reasoning`) is a
--- *model capability claim* and is allowed; the adapter/model validate it at request
--- time, not config time. `vision` is deliberately NOT native-mandatory anywhere.
M.PROTOCOL_NATIVE = {
  openai_chat = { tools = true },
  openai_responses = { tools = true, reasoning = true },
  anthropic_messages = { tools = true, reasoning = true },
  gemini = { tools = true, reasoning = true },
}
--- Default capability values used when a provider definition omits `capabilities`.
--- Conservative vision default: absent capability declarations must not claim support.
M.PROTOCOL_DEFAULTS = {
  openai_chat = { vision = false, tools = true, reasoning = false },
  openai_responses = { vision = false, tools = true, reasoning = true },
  anthropic_messages = { vision = false, tools = true, reasoning = true },
  gemini = { vision = false, tools = true, reasoning = true },
}
--- Env-var name pattern: `api_key_env`/`proxy_env` must name a variable, never carry a
--- credential literal (a real key like `sk-...` or `abc.def` cannot match this).
M.ENV_NAME_PATTERN = "^[A-Za-z_][A-Za-z0-9_]*$"
--- 凭据键名：配置树中任何路径出现这些键且值为非空字符串即拒绝（字面量凭据）。
M.SECRET_KEYS = {
  api_key = true,
  apikey = true,
  token = true,
  secret = true,
  password = true,
  access_key = true,
}

--- 当前有效配置树（`configure` 写入；setup 前为 nil）。
M.effective = nil

--- Build a typed error object (schema contract §4.6).
---@param code string one of schema.ERROR.*
---@param message string detail
---@param cause? table|nil low-level cause
---@return table error
function M.error(code, message, cause)
  return schema.new_error(code, message, cause)
end

--- Recursively search for a literal credential under `node`.
---@param node table|unknown
---@param path string dotted path for diagnostics
---@return string|nil found_path first path carrying a literal secret value
local function find_secret(node, path)
  if type(node) ~= "table" then
    return nil
  end
  for k, v in pairs(node) do
    local p = path == "" and tostring(k) or (path .. "." .. tostring(k))
    if type(k) == "string" and M.SECRET_KEYS[k] and type(v) == "string" and v ~= "" then
      return p
    end
    local found = find_secret(v, p)
    if found then
      return found
    end
  end
  return nil
end

--- Check a provider definition's cross-field constraints (protocol enum,
--- capability matrix, env-name references, structure). Fail-closed on any
--- violation; returns the first error.
---@param pid string provider id (diagnostics)
---@param def table provider definition
---@return table|nil err typed error on failure
local function check_provider_definition(pid, def)
  if type(def) ~= "table" then
    return M.error(schema.ERROR.INVALID_ARGUMENT, ("provider %q: definition must be a table"):format(tostring(pid)))
  end
  if type(def.protocol) ~= "string" or not vim.tbl_contains(M.PROTOCOLS, def.protocol) then
    return M.error(
      schema.ERROR.INVALID_ARGUMENT,
      ("provider %q: protocol must be one of %s (got %s)"):format(
        tostring(pid),
        table.concat(M.PROTOCOLS, ", "),
        vim.inspect(def.protocol)
      )
    )
  end
  if type(def.base_url) ~= "string" or def.base_url == "" then
    return M.error(
      schema.ERROR.INVALID_ARGUMENT,
      ("provider %q: base_url must be a non-empty string"):format(tostring(pid))
    )
  end
  if
    def.api_key_env ~= nil and (type(def.api_key_env) ~= "string" or not def.api_key_env:match(M.ENV_NAME_PATTERN))
  then
    return M.error(
      schema.ERROR.INVALID_ARGUMENT,
      ("provider %q: api_key_env must be an environment variable name (credentials are never literals)"):format(
        tostring(pid)
      )
    )
  end
  if def.model ~= nil and (type(def.model) ~= "string" or def.model == "") then
    return M.error(
      schema.ERROR.INVALID_ARGUMENT,
      ("provider %q: model must be a non-empty string"):format(tostring(pid))
    )
  end
  if
    def.context_window ~= nil
    and (
      type(def.context_window) ~= "number"
      or math.floor(def.context_window) ~= def.context_window
      or def.context_window <= 0
    )
  then
    return M.error(
      schema.ERROR.INVALID_ARGUMENT,
      ("provider %q: context_window must be a positive integer"):format(tostring(pid))
    )
  end
  -- Capability matrix: declaring `false` for a protocol-native channel conflicts.
  if type(def.capabilities) == "table" then
    local native = M.PROTOCOL_NATIVE[def.protocol] or {}
    for chan, native_on in pairs(native) do
      if def.capabilities[chan] == false and native_on then
        return M.error(
          schema.ERROR.PROTOCOL,
          ("provider %q: capability %q=false conflicts with protocol %s native channel"):format(
            tostring(pid),
            chan,
            def.protocol
          )
        )
      end
    end
  end
  if def.request ~= nil and type(def.request) ~= "table" then
    return M.error(schema.ERROR.INVALID_ARGUMENT, ("provider %q: request must be a table"):format(tostring(pid)))
  end
  return nil
end

--- Built-in protocol providers (mock/echo) live in the protocol registry, not in
--- `provider.definitions`. They are always valid `provider.default` targets.
M.BUILTIN_PROVIDERS = { mock = true, echo = true }

--- Check the `provider` block cross-field constraints: `default` must be a built-in
--- provider or exist in `definitions`; every definition must pass
--- `check_provider_definition`. `definitions` may be empty (pure built-in mode).
---@param provider table|nil provider block
---@return table|nil err
local function check_provider_block(provider)
  if type(provider) ~= "table" then
    return M.error(
      schema.ERROR.INVALID_ARGUMENT,
      "provider block must be a table (LazyVim opts `provider = { default, definitions }`)"
    )
  end
  if type(provider.definitions) ~= "table" then
    return M.error(schema.ERROR.INVALID_ARGUMENT, "provider.definitions must be a table")
  end
  local ids = {}
  for pid, def in pairs(provider.definitions) do
    ids[#ids + 1] = pid
    local err = check_provider_definition(pid, def)
    if err then
      return err
    end
  end
  if type(provider.default) ~= "string" or provider.default == "" then
    return M.error(schema.ERROR.INVALID_ARGUMENT, "provider.default must be a non-empty string")
  end
  if M.BUILTIN_PROVIDERS[provider.default] then
    return nil
  end
  if not provider.definitions[provider.default] then
    if #ids == 0 then
      return M.error(
        schema.ERROR.INVALID_ARGUMENT,
        ("provider.default %q is not a built-in provider (mock/echo) and no definitions are declared"):format(
          provider.default
        )
      )
    end
    return M.error(
      schema.ERROR.INVALID_ARGUMENT,
      ("provider.default %q does not exist in definitions (known: %s)"):format(
        provider.default,
        table.concat(ids, ", ")
      )
    )
  end
  return nil
end

--- Validate the effective (merged) configuration tree. Fail-closed:
---   * unknown top-level keys (except `extensions`) are configuration errors;
---   * literal credentials anywhere are rejected (only `api_key_env` references);
---   * provider block cross-field constraints (protocol/capabilities/default).
---@param cfg table merged configuration tree
---@return table|nil err typed error on failure
--- Allowed keys of the `mcp` config block (W7; fail-closed unknown-key style).
M.MCP_KEYS = {
  enabled = true,
  servers_file = true,
}
--- Allowed keys of the `skills` config block and its `roots` sub-block (W7;
--- roots mirror skills.discover default-roots kinds: bundled/config/project).
M.SKILLS_KEYS = {
  enabled = true,
  roots = true,
}
M.SKILLS_ROOTS_KEYS = {
  bundled = true,
  config = true,
  project = true,
}

--- Check the `mcp` block (W7): enabled toggle + project-relative servers file
--- path. Unknown keys are fail-closed configuration errors (same style as the
--- top-level key check). The servers file itself is validated by
--- `mcp.config.load` at assembly time; here only the opts contract is checked.
---@param mcp table|nil mcp block
---@return table|nil err
local function check_mcp_block(mcp)
  if mcp == nil then
    return nil
  end
  if type(mcp) ~= "table" then
    return M.error(schema.ERROR.INVALID_ARGUMENT, "mcp block must be a table")
  end
  for k in pairs(mcp) do
    if type(k) == "string" and not M.MCP_KEYS[k] then
      return M.error(schema.ERROR.INVALID_ARGUMENT, ("mcp: unknown key %q (known: enabled, servers_file)"):format(k))
    end
  end
  if mcp.enabled ~= nil and type(mcp.enabled) ~= "boolean" then
    return M.error(schema.ERROR.INVALID_ARGUMENT, "mcp.enabled must be a boolean")
  end
  if mcp.servers_file ~= nil and (type(mcp.servers_file) ~= "string" or mcp.servers_file == "") then
    return M.error(schema.ERROR.INVALID_ARGUMENT, "mcp.servers_file must be a non-empty project-relative path")
  end
  return nil
end

--- Check the `skills` block (W7): enabled toggle + discovery-root switches
--- (bundled/config/project). Unknown keys are fail-closed errors.
---@param skills table|nil skills block
---@return table|nil err
local function check_skills_block(skills)
  if skills == nil then
    return nil
  end
  if type(skills) ~= "table" then
    return M.error(schema.ERROR.INVALID_ARGUMENT, "skills block must be a table")
  end
  for k in pairs(skills) do
    if type(k) == "string" and not M.SKILLS_KEYS[k] then
      return M.error(schema.ERROR.INVALID_ARGUMENT, ("skills: unknown key %q (known: enabled, roots)"):format(k))
    end
  end
  if skills.enabled ~= nil and type(skills.enabled) ~= "boolean" then
    return M.error(schema.ERROR.INVALID_ARGUMENT, "skills.enabled must be a boolean")
  end
  if skills.roots ~= nil then
    if type(skills.roots) ~= "table" then
      return M.error(schema.ERROR.INVALID_ARGUMENT, "skills.roots must be a table")
    end
    for k, v in pairs(skills.roots) do
      if type(k) == "string" and not M.SKILLS_ROOTS_KEYS[k] then
        return M.error(
          schema.ERROR.INVALID_ARGUMENT,
          ("skills.roots: unknown key %q (known: bundled, config, project)"):format(k)
        )
      end
      if type(k) == "string" and type(v) ~= "boolean" then
        return M.error(schema.ERROR.INVALID_ARGUMENT, ("skills.roots.%s must be a boolean"):format(k))
      end
    end
  end
  return nil
end

local function validate_config(cfg)
  if type(cfg) ~= "table" then
    return M.error(schema.ERROR.INVALID_ARGUMENT, "configure: opts must merge into a table")
  end
  for k in pairs(cfg) do
    if type(k) == "string" and not vim.tbl_contains(M.CORE_KEYS, k) then
      return M.error(
        schema.ERROR.INVALID_ARGUMENT,
        ("configure: unknown top-level key %q (known: %s)"):format(k, table.concat(M.CORE_KEYS, ", "))
      )
    end
  end
  local secret_path = find_secret(cfg, "")
  if secret_path then
    return M.error(
      schema.ERROR.INVALID_ARGUMENT,
      ("configure: literal credential at %q (use api_key_env env-name references)"):format(secret_path)
    )
  end
  local err = check_provider_block(cfg.provider)
  if err then
    return err
  end
  -- W7: mcp/skills extension-content blocks (fail-closed, unknown keys rejected).
  local merr = check_mcp_block(cfg.mcp)
  if merr then
    return merr
  end
  local serr = check_skills_block(cfg.skills)
  if serr then
    return serr
  end
  return nil
end

--- Merge defaults + user opts into the effective configuration tree and validate it.
--- This is the single configuration entry used by `maxa.setup(opts)`; LazyVim merges
--- multiple `opts` tables before calling setup, so this receives the final user opts.
---@param defaults table bundled defaults (lua/maxa/init.lua `M.defaults`)
---@param opts? table user configuration (LazyVim opts)
---@return table merged effective config
---@return table|nil err typed error on failure (effective is NOT updated on failure)
function M.configure(defaults, opts)
  local merged = vim.tbl_deep_extend("force", {}, defaults or {}, opts or {})
  local err = validate_config(merged)
  if err then
    return nil, err
  end
  M.effective = merged
  return merged, nil
end

--- Resolve a config key from the effective tree (dotted path).
---@param key? string dotted key path (nil returns the whole tree)
---@return unknown value
function M.get(key)
  if type(M.effective) ~= "table" then
    return nil
  end
  if key == nil then
    return M.effective
  end
  local cur = M.effective
  for part in tostring(key):gmatch("[^.]+") do
    if type(cur) ~= "table" then
      return nil
    end
    cur = cur[part]
  end
  return cur
end

--- Normalize a provider base_url: strip trailing slashes (aligns with the gateway
--- factory behavior in `lua/plugins/ai.lua` `normalize_gateway_base_url`).
---@param url string
---@return string
function M.normalize_base_url(url)
  return tostring(url or ""):gsub("/+$", "")
end

--- Resolve a provider definition into a normalized runtime record.
---
--- Reads from a merged configuration tree (returned by `M.configure`/`M.effective`).
--- The config tree is never mutated and never contains credential values; the
--- resolved env key value is fetched at call time and lives only in the returned record.
---
---@param cfg table merged configuration tree (e.g. M.effective)
---@param id? string provider id; defaults to `provider.default`
---@return table|nil record normalized provider record
---@return table|nil err typed error (schema.new_error) on failure
function M.resolve_provider(cfg, id)
  if type(cfg) ~= "table" or type(cfg.provider) ~= "table" then
    return nil,
      M.error(
        schema.ERROR.INVALID_ARGUMENT,
        "resolve_provider: no provider block configured (LazyVim opts `provider = { default, definitions }`)"
      )
  end
  local provider = cfg.provider
  if type(provider.definitions) ~= "table" then
    return nil, M.error(schema.ERROR.INVALID_ARGUMENT, "resolve_provider: provider.definitions must be a table")
  end
  local pid = id or provider.default
  if type(pid) ~= "string" or pid == "" then
    return nil, M.error(schema.ERROR.INVALID_ARGUMENT, "resolve_provider: provider id must be a non-empty string")
  end
  local def = provider.definitions[pid]
  if not def then
    local known = {}
    for k in pairs(provider.definitions) do
      known[#known + 1] = k
    end
    return nil,
      M.error(
        schema.ERROR.INVALID_ARGUMENT,
        ("resolve_provider: unknown provider %q (known: %s)"):format(pid, table.concat(known, ", "))
      )
  end
  local err = check_provider_definition(pid, def)
  if err then
    return nil, err
  end
  local protocol = def.protocol
  local capabilities = vim.tbl_deep_extend("force", {}, M.PROTOCOL_DEFAULTS[protocol] or {}, def.capabilities or {})
  local request = vim.tbl_deep_extend("force", {}, def.request or {})
  local record = {
    id = pid,
    protocol = protocol,
    base_url = M.normalize_base_url(def.base_url),
    api_key_env = def.api_key_env,
    -- Resolved at call time; never persisted, never part of any artifact.
    api_key = def.api_key_env and os.getenv(def.api_key_env) or nil,
    model = def.model,
    -- Optional provider context window (tokens). nil when undeclared: the
    -- orchestrator default usage provider falls back to DEFAULT_CONTEXT_WINDOW.
    context_window = def.context_window,
    capabilities = capabilities,
    request = request,
    adapter = nil,
  }
  -- Bind the protocol adapter when the registry has one registered for this protocol.
  local ok, proto = pcall(require, "maxa.runtime.protocol")
  if ok and type(proto) == "table" and type(proto.get_adapter) == "function" then
    record.adapter = proto.get_adapter(protocol)
  end
  record.bind = function(self, adapter_instance)
    record.adapter = adapter_instance
    return record
  end
  return record, nil
end

--- Find the project root by walking upward from `start` looking for a `.maxa/`
--- directory (state file location / project marker). Never falls back to the
--- development mother repository's `.supermax/`.
---@param start? string starting directory (default: current working directory)
---@return string|nil root absolute project root containing `.maxa/`
---@return string|nil err when no `.maxa/` marker is found upward
function M.find_project_root(start)
  local dir = vim.fn.fnamemodify(start or vim.fn.getcwd(), ":p")
  for _ = 1, 64 do
    if vim.uv.fs_stat(dir .. "/" .. M.STATE_DIR) then
      return dir, nil
    end
    local parent = vim.fn.fnamemodify(dir, ":h")
    if parent == dir then
      break
    end
    dir = parent
  end
  return nil,
    M.error(
      schema.ERROR.INVALID_ARGUMENT,
      "find_project_root: no .maxa/ project marker found upward from " .. tostring(start or vim.fn.getcwd())
    )
end

--- Load the project runtime state (`<root>/.maxa/state.yaml`). Missing state file
--- is NOT an error: it means the project is not initialized yet.
---@param root string project root
---@return table|nil state decoded state mapping
---@return table|nil err typed error on unreadable/invalid state
function M.load_state(root)
  local path = root .. "/" .. M.STATE_YAML
  if not vim.uv.fs_stat(path) then
    return nil, nil
  end
  local fh = assert(io.open(path, "rb"))
  local body = fh:read("*a")
  fh:close()
  local ok, data = pcall(yaml.decode, body)
  if not ok then
    return nil, M.error(schema.ERROR.CONFIGURATION, "load_state: state.yaml decode failed", { path = path })
  end
  if type(data) ~= "table" then
    return nil, M.error(schema.ERROR.CONFIGURATION, "load_state: state.yaml must decode to a mapping", { path = path })
  end
  return data, nil
end

--- Minimal YAML mapping serializer for `.maxa/state.yaml` (生态缺位最小替代：
--- the runtime only ever writes this controlled flat state mapping; TinyYaml is
--- decode-only). Supports scalar values and one level of nested mappings.
---@param state table state mapping (flat scalars + optional one-level nested maps)
---@return string yaml text
local function encode_state(state)
  local lines = {}
  local function scalar(v)
    if v == nil then
      return "null"
    end
    if type(v) == "boolean" then
      return v and "true" or "false"
    end
    if type(v) == "number" then
      return tostring(v)
    end
    local s = tostring(v)
    if s:find("[%s:#]") or s == "" then
      return ("%q"):format(s)
    end
    return s
  end
  for k, v in pairs(state) do
    if type(v) == "table" then
      lines[#lines + 1] = tostring(k) .. ":"
      for kk, vv in pairs(v) do
        lines[#lines + 1] = ("  %s: %s"):format(tostring(kk), scalar(vv))
      end
    else
      lines[#lines + 1] = ("%s: %s"):format(tostring(k), scalar(v))
    end
  end
  table.sort(lines)
  return table.concat(lines, "\n") .. "\n"
end

--- Save the project runtime state (`<root>/.maxa/state.yaml`). Creates the
--- `.maxa/` directory when missing. The state file carries runtime status only
--- (schema_version/project_id/created/updated/status); configuration lives in
--- LazyVim opts, never here.
---@param root string project root
---@param state table state mapping to persist
---@return string|nil path written file path
---@return table|nil err typed error on write failure
function M.save_state(root, state)
  if type(state) ~= "table" then
    return nil, M.error(schema.ERROR.INVALID_ARGUMENT, "save_state: state must be a table")
  end
  local dir = root .. "/" .. M.STATE_DIR
  vim.fn.mkdir(dir, "p")
  local path = dir .. "/state.yaml"
  local fh, ferr = io.open(path, "wb")
  if not fh then
    return nil, M.error(schema.ERROR.PERSISTENCE, ("save_state: cannot open %s: %s"):format(path, tostring(ferr)))
  end
  local ok, werr = pcall(fh.write, fh, encode_state(state))
  fh:close()
  if not ok then
    return nil, M.error(schema.ERROR.PERSISTENCE, ("save_state: write failed: %s"):format(tostring(werr)))
  end
  return path, nil
end

return M
