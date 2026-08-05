-- filepath: lua/maxa/runtime/mcp/config.lua
--- maxa project MCP configuration: `.maxa/mcp/servers.yaml` load + validation.
---
--- Contract (see `specs/modules/supermax-configuration/spec.md` §MCP server
--- schema and `specs/modules/mcp-skill-runtime/spec.md`):
---   * project-local file `<root>/.maxa/mcp/servers.yaml`; there is NO
---     cross-project or development `.supermax/` fallback. A missing file is an
---     EMPTY configuration, never an error.
---   * schema:
---       schema_version: 1
---       servers:
---         server-id:
---           enabled: true|false           (optional, default true)
---           transport: stdio              (optional, default "stdio"; only stdio)
---           command: executable           (required, non-empty string)
---           args: [string...]             (optional, default {})
---           env: { KEY: scalar }          (optional; KEY must be an env-name)
---           cwd: string                   (optional, default <project root>)
---           request_timeout_ms: int|null  (optional, default 300000)
---           startup_timeout_ms: int|null  (optional, default 30000)
---   * substitution: `${PROJECT_ROOT}` resolves to the project root; `${VAR}`
---     resolves through the process environment. A missing environment reference
---     marks ONLY that server unavailable (explicit unavailable-server state,
---     spec failure policy); structural violations are hard configuration errors
---     classified before any process spawn.
---   * secrets are never persisted: values derived from `${VAR}` are flagged and
---     redacted in `snapshot()`/dumps (env-ref-derived values are the secret
---     class; `${PROJECT_ROOT}` expansion is not).
---   * `diff(old, new)` computes added/removed/changed/unchanged with field-level
---     detail for changed servers (config reload policy).
---
--- Fail-closed validation style mirrors `config/init.lua`; typed errors come
--- from `schema.new_error` (code = schema.ERROR.CONFIGURATION). This module
--- never loads codecompanion.* / mcphub.* / lua/util/hooks/* and never spawns a
--- process (spawning is the server layer's job).

local schema = require("maxa.runtime.schema")
local yaml = require("maxa.runtime.config.yaml")

local M = {}
M.name = "mcp.config"

--- Project-relative servers file path (under the project root).
M.SERVERS_YAML = ".maxa/mcp/servers.yaml"
--- Supported schema version.
M.SCHEMA_VERSION = 1
--- Default request timeout (ms) when a server omits `request_timeout_ms`.
M.DEFAULT_REQUEST_TIMEOUT_MS = 300000
--- Default startup timeout (ms) when a server omits `startup_timeout_ms`.
M.DEFAULT_STARTUP_TIMEOUT_MS = 30000

--- Server-level keys accepted by the schema (unknown keys are fail-closed errors).
M.SERVER_KEYS = {
  enabled = true,
  transport = true,
  command = true,
  args = true,
  env = true,
  cwd = true,
  request_timeout_ms = true,
  startup_timeout_ms = true,
}

--- Env-name pattern for `env` keys and `${VAR}` references.
M.ENV_NAME_PATTERN = "^[A-Za-z_][A-Za-z0-9_]*$"
--- Redaction marker for env-ref-derived values in snapshots.
M.REDACTED = "<redacted>"

--- Build a typed configuration error.
---@param message string detail (file/field path included)
---@param cause? table|nil low-level cause
---@return table err typed error (schema.ERROR.CONFIGURATION)
local function config_error(message, cause)
  return schema.new_error(schema.ERROR.CONFIGURATION, message, cause)
end

--- Deep equality for config values (scalars, lists, maps).
---@param a any
---@param b any
---@return boolean
local function deep_equal(a, b)
  if a == b then
    return true
  end
  if type(a) ~= "table" or type(b) ~= "table" then
    return false
  end
  local seen = {}
  for k, v in pairs(a) do
    if not deep_equal(v, b[k]) then
      return false
    end
    seen[k] = true
  end
  for k in pairs(b) do
    if not seen[k] then
      return false
    end
  end
  return true
end

--- Detect the TinyYaml `null` marker (decode of `null`/`~` scalars) or Lua nil.
---@param v any
---@return boolean
local function is_null(v)
  if v == nil then
    return true
  end
  return type(v) == "table" and tostring(v) == "yaml.null"
end

--- Substitute `${PROJECT_ROOT}` / `${VAR}` references in a scalar string.
--- References are pre-validated (structural violations are hard errors); a
--- missing environment variable is reported through `missing_var` so the caller
--- can mark ONLY that server unavailable.
---@param value string raw value
---@param project_root string absolute project root
---@param env table|nil env lookup (defaults to os.getenv)
---@return string|nil resolved value
---@return string|nil err structural reference error (bad syntax)
---@return string|nil missing_var first missing environment variable name
---@return boolean had_env_ref true when at least one `${VAR}` reference occurred
local function substitute(value, project_root, env)
  local missing
  local had_env_ref = false
  -- Pass 1: validate every reference (bad names / unterminated `${`).
  local pos = 1
  while true do
    local s, e = value:find("%$%{", pos)
    if not s then
      break
    end
    local name = value:match("%$%{([^}]+)%}", s)
    if not name then
      return nil, ("unterminated ${ reference in %q"):format(value), nil, false
    end
    if not name:match(M.ENV_NAME_PATTERN) then
      return nil, ("invalid reference ${%s} in %q"):format(name, value), nil, false
    end
    if name ~= "PROJECT_ROOT" then
      had_env_ref = true
      local v = env and env[name] or os.getenv(name)
      if v == nil or v == "" then
        missing = missing or name
      end
    end
    pos = e + 1
  end
  -- Pass 2: expand.
  local out = value:gsub("%$%{([^}]+)%}", function(name)
    if name == "PROJECT_ROOT" then
      return project_root
    end
    local v = env and env[name] or os.getenv(name)
    if v == nil or v == "" then
      return ""
    end
    return v
  end)
  -- A leftover `$` (e.g. `$HOME` or `$$`) is a structural error.
  if out:find("%$") then
    return nil, ("unrecognized `$` reference in %q"):format(value), nil, false
  end
  return out, nil, missing, had_env_ref
end

--- Validate + normalize one server declaration (no substitution yet).
---@param id string server id (diagnostics)
---@param decl any raw declaration
---@param root string project root (diagnostics only)
---@return table|nil normalized { enabled, transport, command, args, env, cwd,
---         request_timeout_ms, startup_timeout_ms }
---@return table|nil err typed configuration error
local function normalize_server(id, decl, root)
  local path = ("servers.%s"):format(id)
  if type(decl) ~= "table" then
    return nil, config_error(("%s: server declaration must be a mapping (got %s)"):format(path, type(decl)))
  end
  for k in pairs(decl) do
    if type(k) == "string" and not M.SERVER_KEYS[k] then
      return nil,
        config_error(
          ("%s: unknown server key %q (known: enabled, transport, command, args, env, cwd, request_timeout_ms, startup_timeout_ms)"):format(
            path,
            k
          )
        )
    end
  end
  if type(decl.command) ~= "string" or decl.command == "" then
    return nil,
      config_error(("%s: command must be a non-empty string (missing command classified before spawn)"):format(path))
  end
  local transport = decl.transport == nil and "stdio" or decl.transport
  if transport ~= "stdio" then
    return nil, config_error(('%s: transport must be "stdio" (got %s)'):format(path, vim.inspect(transport)))
  end
  local enabled = decl.enabled == nil and true or decl.enabled
  if type(enabled) ~= "boolean" then
    return nil, config_error(("%s: enabled must be a boolean"):format(path))
  end
  local args = decl.args == nil and {} or decl.args
  if type(args) ~= "table" or vim.tbl_islist(args) ~= true then
    return nil, config_error(("%s: args must be a list of strings"):format(path))
  end
  for i, a in ipairs(args) do
    if type(a) ~= "string" then
      return nil, config_error(("%s: args[%d] must be a string (got %s)"):format(path, i, type(a)))
    end
  end
  local env = decl.env == nil and {} or decl.env
  -- An empty table is a valid (empty) mapping; only a NON-empty list is wrong.
  if type(env) ~= "table" or (next(env) ~= nil and vim.tbl_islist(env) == true) then
    return nil, config_error(("%s: env must be a mapping of scalar values"):format(path))
  end
  for k, v in pairs(env) do
    if type(k) ~= "string" or not k:match(M.ENV_NAME_PATTERN) then
      return nil, config_error(("%s: env key %q is not an environment variable name"):format(path, tostring(k)))
    end
    if type(v) == "boolean" then
      env[k] = v and "true" or "false"
    elseif type(v) == "number" then
      env[k] = tostring(v)
    elseif type(v) ~= "string" then
      return nil, config_error(("%s: env.%s must be a scalar (got %s)"):format(path, k, type(v)))
    end
  end
  local cwd = decl.cwd
  if cwd ~= nil and type(cwd) ~= "string" then
    return nil, config_error(("%s: cwd must be a string"):format(path))
  end
  local function check_timeout(field, default)
    local v = decl[field]
    if v == nil then
      return default, nil
    end
    if is_null(v) then
      return nil, nil -- explicit null = no timeout
    end
    if type(v) ~= "number" or v <= 0 or v % 1 ~= 0 then
      return nil,
        config_error(("%s: %s must be a positive integer or null (got %s)"):format(path, field, vim.inspect(v)))
    end
    return v, nil
  end
  local request_timeout_ms, rerr = check_timeout("request_timeout_ms", M.DEFAULT_REQUEST_TIMEOUT_MS)
  if rerr then
    return nil, rerr
  end
  local startup_timeout_ms, serr = check_timeout("startup_timeout_ms", M.DEFAULT_STARTUP_TIMEOUT_MS)
  if serr then
    return nil, serr
  end
  return {
    enabled = enabled,
    transport = transport,
    command = decl.command,
    args = args,
    env = env,
    cwd = cwd, -- substituted later; nil = project root
    request_timeout_ms = request_timeout_ms,
    startup_timeout_ms = startup_timeout_ms,
  },
    nil
end

--- Load and validate `.maxa/mcp/servers.yaml` under `root`.
---
--- Missing file -> empty configuration (NOT an error). Structural violations are
--- fail-closed typed errors (schema.ERROR.CONFIGURATION) classified before any
--- spawn. Servers whose values reference a missing environment variable are
--- reported in `cfg.unavailable` and excluded from `cfg.servers` (explicit
--- unavailable-server state, never a global config failure).
---
---@param root string project root (absolute preferred)
---@param opts? table {
---   servers_file?: string project-relative servers file path (default
---     M.SERVERS_YAML; W7: honored from the effective `mcp.servers_file` config)
--- }
---@return table|nil cfg {
---   version = 1,
---   project_root = string,
---   servers = { [id] = normalized+substituted record },
---   unavailable = { [id] = reason },
---   warnings = string[],
---   source = string|nil file path (nil for empty config),
--- }
---@return table|nil err typed configuration error on structural violation
function M.load(root, opts)
  if type(root) ~= "string" or root == "" then
    return nil, config_error("mcp.config.load: project root must be a non-empty string")
  end
  local project_root = vim.fn.fnamemodify(root, ":p"):gsub("/$", "")
  local servers_file = (opts and type(opts.servers_file) == "string" and opts.servers_file ~= "") and opts.servers_file
    or M.SERVERS_YAML
  local path = root .. "/" .. servers_file
  if not vim.uv.fs_stat(path) then
    -- Missing file = empty configuration, never an error, never `.supermax/`
    -- fallback: the runtime only reads the target-project `.maxa/mcp/` root.
    return { version = M.SCHEMA_VERSION, project_root = project_root, servers = {}, unavailable = {}, warnings = {} },
      nil
  end
  local fh, ferr = io.open(path, "rb")
  if not fh then
    return nil, config_error(("mcp.config.load: cannot open %s: %s"):format(path, tostring(ferr)))
  end
  local body = fh:read("*a")
  fh:close()
  local raw, yerr = yaml.decode(body)
  if not raw then
    return nil, config_error(("mcp.config.load: %s: %s"):format(path, tostring(yerr)))
  end
  if type(raw) ~= "table" or vim.tbl_islist(raw) == true then
    return nil, config_error(("mcp.config.load: %s: document must be a mapping"):format(path))
  end
  for k in pairs(raw) do
    if type(k) == "string" and k ~= "schema_version" and k ~= "servers" then
      return nil,
        config_error(("mcp.config.load: %s: unknown top-level key %q (known: schema_version, servers)"):format(path, k))
    end
  end
  local version = raw.schema_version
  if type(version) ~= "number" or version % 1 ~= 0 then
    return nil,
      config_error(
        ("mcp.config.load: %s: schema_version must be an integer (missing/unsupported version classified before spawn)"):format(
          path
        )
      )
  end
  if version ~= M.SCHEMA_VERSION then
    return nil,
      config_error(
        ("mcp.config.load: %s: unsupported schema_version %d (supported: %d)"):format(path, version, M.SCHEMA_VERSION)
      )
  end
  local servers = raw.servers
  if servers == nil then
    servers = {}
  end
  if type(servers) ~= "table" or (next(servers) ~= nil and vim.tbl_islist(servers) == true) then
    return nil,
      config_error(("mcp.config.load: %s: servers must be a mapping of server-id -> declaration"):format(path))
  end

  local cfg =
    { version = version, project_root = project_root, servers = {}, unavailable = {}, warnings = {}, source = path }
  for id, decl in pairs(servers) do
    if type(id) ~= "string" or id == "" then
      return nil, config_error(("mcp.config.load: %s: server ids must be non-empty strings"):format(path))
    end
    local norm, nerr = normalize_server(id, decl, root)
    if nerr then
      return nil, nerr
    end
    local env = {}
    for k, v in pairs(norm.env) do
      env[k] = v
    end
    -- Substitution: structural reference errors are hard errors; a missing
    -- environment variable marks only this server unavailable. `had` is
    -- tracked PER FIELD so only env-ref-derived values become secret-class.
    local ref_err, missing
    local function resolve_field(field, value)
      local resolved, rerr, miss, had = substitute(value, project_root, nil)
      if rerr then
        ref_err = config_error(("mcp.config.load: %s.%s: %s"):format(path, id, rerr))
        return false, false
      end
      missing = missing or miss
      return resolved, had
    end
    local command = resolve_field("command", norm.command)
    if ref_err then
      return nil, ref_err
    end
    local args = {}
    local secret_args = {}
    for i, a in ipairs(norm.args) do
      local r, had = resolve_field(("args[%d]"):format(i), a)
      if ref_err then
        return nil, ref_err
      end
      args[i] = r
      if had then
        secret_args[i] = true
      end
    end
    local env_out = {}
    local env_secret_keys = {}
    for k, v in pairs(env) do
      local r, had = resolve_field(("env.%s"):format(k), v)
      if ref_err then
        return nil, ref_err
      end
      env_out[k] = r
      if had then
        env_secret_keys[k] = true
      end
    end
    local cwd = norm.cwd
    local cwd_secret = false
    if cwd ~= nil then
      local r, had = resolve_field("cwd", cwd)
      if ref_err then
        return nil, ref_err
      end
      cwd = r
      cwd_secret = had
    else
      cwd = project_root
    end
    if missing then
      -- Explicit unavailable-server state (spec failure policy: only the
      -- affected server is marked unavailable).
      cfg.unavailable[id] = ("env reference missing: %s"):format(missing)
      cfg.warnings[#cfg.warnings + 1] = ("server %q unavailable: %s"):format(id, cfg.unavailable[id])
    else
      cfg.servers[id] = {
        id = id,
        enabled = norm.enabled,
        transport = norm.transport,
        command = command,
        args = args,
        env = env_out,
        cwd = cwd,
        request_timeout_ms = norm.request_timeout_ms,
        startup_timeout_ms = norm.startup_timeout_ms,
        -- secret-class tracking (never persisted; snapshot redacts these):
        env_secret_keys = env_secret_keys,
        secret_args = secret_args,
        cwd_secret = cwd_secret or false,
      }
    end
  end
  return cfg, nil
end

--- Field-level diff between two loaded configurations.
---
---@param old_cfg table|nil previous config (nil = empty baseline)
---@param new_cfg table|nil new config (nil = empty baseline)
---@return table {
---   added = { [id] = cfg },
---   removed = { [id] = cfg },
---   changed = { [id] = { old = cfg, new = cfg, fields = string[] } },
---   unchanged = { [id] = cfg },
--- }
function M.diff(old_cfg, new_cfg)
  local old_servers = old_cfg and old_cfg.servers or {}
  local new_servers = new_cfg and new_cfg.servers or {}
  local out = { added = {}, removed = {}, changed = {}, unchanged = {} }
  local COMPARE_FIELDS = {
    "enabled",
    "transport",
    "command",
    "args",
    "env",
    "cwd",
    "request_timeout_ms",
    "startup_timeout_ms",
  }
  for id, old in pairs(old_servers) do
    local new = new_servers[id]
    if new == nil then
      out.removed[id] = old
    else
      local fields = {}
      for _, f in ipairs(COMPARE_FIELDS) do
        if not deep_equal(old[f], new[f]) then
          fields[#fields + 1] = f
        end
      end
      if #fields > 0 then
        out.changed[id] = { old = old, new = new, fields = fields }
      else
        out.unchanged[id] = new
      end
    end
  end
  for id, new in pairs(new_servers) do
    if old_servers[id] == nil then
      out.added[id] = new
    end
  end
  return out
end

--- Redacted deep snapshot of a loaded configuration: values derived from
--- `${VAR}` environment references are replaced with `M.REDACTED` so resolved
--- secrets are never persisted into dumps/logs. `${PROJECT_ROOT}` expansions
--- are not secrets and stay readable.
---@param cfg table loaded config (M.load result)
---@return table redacted copy { version, project_root, servers, unavailable, warnings }
function M.snapshot(cfg)
  local out = {
    version = cfg.version,
    project_root = cfg.project_root,
    servers = {},
    unavailable = vim.deepcopy(cfg.unavailable or {}),
    warnings = vim.deepcopy(cfg.warnings or {}),
    source = cfg.source,
  }
  for id, s in pairs(cfg.servers or {}) do
    local rec = {
      id = id,
      enabled = s.enabled,
      transport = s.transport,
      command = s.command,
      args = {},
      env = {},
      cwd = s.cwd,
      request_timeout_ms = s.request_timeout_ms,
      startup_timeout_ms = s.startup_timeout_ms,
    }
    for i, a in ipairs(s.args) do
      rec.args[i] = s.secret_args and s.secret_args[i] and M.REDACTED or a
    end
    for k, v in pairs(s.env) do
      rec.env[k] = s.env_secret_keys and s.env_secret_keys[k] and M.REDACTED or v
    end
    if s.cwd_secret then
      rec.cwd = M.REDACTED
    end
    out.servers[id] = rec
  end
  return out
end

return M
