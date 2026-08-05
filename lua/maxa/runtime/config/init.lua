-- filepath: lua/maxa/runtime/config/init.lua
--- maxa runtime project configuration (phase-1 W3: full schema + provider resolution).
---
--- Delivers, per `.supermax/drafts/phase1-implementation-plan.md` §4.5 and
--- `specs/modules/supermax-configuration/spec.md`:
---   * project-root binding : walks upward from the caller's working directory looking
---     for a `.maxa/runtime.yaml` marker; if none is found it fails closed (no fallback
---     to the development mother repository's `.supermax/`).
---   * immutable snapshot   : the `.maxa/runtime.yaml` file is read once, validated,
---     and frozen into a read-only snapshot; later reads (`get`) never re-parse.
---   * fail-closed parsing  : unknown *core* fields and unknown nested struct fields
---     are validation errors; credentials never enter the snapshot (only the names of
---     read-only env vars are allowed, per `api_key_env`; a literal secret value is
---     rejected). `.supermax/` is never a runtime configuration source.
---   * full schema          : `runtime.yaml` covers the spec's complete field set
---     (schema_version/project_id/provider{default,definitions}/history/orchestrator/
---     ui/skills/mcp/status/extensions). The phase-0 top-level string `provider` and
---     `model` fields are deprecated and now fail closed (not compatible).
---   * capability matrix    : per-provider `capabilities` are checked against the
---     protocol's native channels (`provider-contract` spec matrix); declaring `false`
---     for a channel the protocol always provides is a configuration conflict.
---   * provider resolution  : `resolve_provider` normalizes a provider definition
---     (trailing-slash base_url, merged capabilities/request defaults) and binds the
---     protocol adapter instance when the protocol registry has one registered
---     (W4-W7 register real adapters; until then `record.adapter` stays nil and the
---     caller can bind later via `record:bind(adapter)`).
---   * evidence             : each snapshot records its `source` (resolved path,
---     project root, content hash, schema version) for reproducibility and audit.
---
--- Upstream alignment (read-only, never copied): `codecompanion/config.lua`
--- (`config.interactions.chat.*`) + `Chat:new` args + `schema.lua`; gateway behavior
--- from `~/.config/nvim/lua/plugins/ai.lua` `make_llm_gateway_adapter`
--- (name/protocol/base_url validation, trailing-slash normalization); target contract
--- from `specs/modules/supermax-configuration/spec.md` and
--- `specs/modules/provider-contract/spec.md`.
---
--- Dependencies: `maxa.runtime.schema` (validation + typed errors), the self-contained
--- `maxa.runtime.config.yaml` decoder, and `plenary.path` (project-root walk).
--- It never loads `codecompanion.*`/`mcphub.*`/`lua/util/hooks/*`.
----------------------------------------------------------------------------------------
local schema = require("maxa.runtime.schema")
local yaml = require("maxa.runtime.config.yaml")
local Path = require("plenary.path")

local islist = vim.islist or vim.tbl_islist

local M = {}
M.name = "config"

--- Marker file that both locates a project root and carries the runtime overrides.
M.RUNTIME_YAML = ".maxa/runtime.yaml"

--- The four protocol enum values (config must never alias one to another: a provider
--- named `gemini` still has to declare `protocol: gemini` to get native behavior).
M.PROTOCOLS = { "openai_chat", "openai_responses", "anthropic_messages", "gemini" }

--- Protocol-native capability channels (provider-contract spec matrix): channels the
--- protocol provides as a first-class contract regardless of model. Declaring `false`
--- for a native channel is a configuration conflict ("capability 与协议缺省冲突").
--- Declaring `true` for a non-native channel (e.g. openai_chat `reasoning`, which has
--- no standard reasoning channel in the Chat Completions contract — DeepSeek exposes
--- thinking via a model-specific param) is a *model capability claim* and is allowed;
--- the adapter/model validate it at request time, not config time.
--- `vision` is deliberately NOT native-mandatory anywhere: image input exists in every
--- protocol but is always a model property (e.g. deepseek models have none), so both
--- `true` and `false` declarations are legal.
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

--- Validators shared by schema fields.
local function nonempty_string(v)
  if type(v) ~= "string" or v == "" then
    return false, "must be a non-empty string"
  end
  return true
end
local function env_name(v)
  if type(v) ~= "string" or not v:match(M.ENV_NAME_PATTERN) then
    return false, "must be an environment variable name (credentials are never literals)"
  end
  return true
end
local function positive_int(v)
  if not (type(v) == "number" and math.floor(v) == v and v > 0) then
    return false, "must be a positive integer"
  end
  return true
end
local function nonneg_int(v)
  if not (type(v) == "number" and math.floor(v) == v and v >= 0) then
    return false, "must be a non-negative integer"
  end
  return true
end

--- Full `runtime.yaml` schema (spec §4.5 / supermax-configuration spec). Field types
--- extend the shared schema module with config-local composite types:
---   * `struct`: mapping with declared `fields`; unknown keys fail closed.
---   * `map` with `values`: mapping whose values validate against `values`.
---   * `any`: scalar of any non-table type (empty table = null).
--- `extensions` is the only open, forward-compatible core key.
M.runtime_schema = {
  schema_version = { type = "integer", optional = false },
  project_id = { type = "string", optional = false },
  provider = {
    type = "struct",
    optional = true,
    fields = {
      default = { type = "string", optional = true },
      definitions = {
        type = "map",
        optional = true,
        values = {
          type = "struct",
          optional = true,
          fields = {
            protocol = { type = "enum", optional = false, choices = M.PROTOCOLS },
            base_url = { type = "string", optional = false, validate = nonempty_string },
            api_key_env = { type = "string", optional = true, validate = env_name },
            model = { type = "string", optional = false, validate = nonempty_string },
            capabilities = {
              type = "struct",
              optional = true,
              fields = {
                vision = { type = "boolean", optional = true },
                tools = { type = "boolean", optional = true },
                reasoning = { type = "boolean", optional = true },
              },
            },
            request = {
              type = "struct",
              optional = true,
              fields = {
                timeout_ms = { type = "integer", optional = true, validate = positive_int },
                connect_timeout_ms = { type = "integer", optional = true, validate = positive_int },
                retries = { type = "integer", optional = true, validate = nonneg_int },
                proxy_env = { type = "string", optional = true, validate = env_name },
              },
            },
          },
        },
      },
    },
  },
  history = {
    type = "struct",
    optional = true,
    fields = {
      enabled = { type = "boolean", optional = true },
      auto_save = { type = "boolean", optional = true },
      continue_last_session = { type = "boolean", optional = true },
      title_provider = { type = "string", optional = true },
      expiration_days = { type = "integer", optional = true, validate = positive_int },
    },
  },
  orchestrator = {
    type = "struct",
    optional = true,
    fields = {
      tool_concurrency = { type = "integer", optional = true, validate = positive_int },
      watchdog = {
        type = "struct",
        optional = true,
        fields = {
          enabled = { type = "boolean", optional = true },
          timeout_ms = { type = "integer", optional = true, validate = positive_int },
          max_retries = { type = "integer", optional = true, validate = nonneg_int },
        },
      },
      context_stop = {
        type = "struct",
        optional = true,
        fields = {
          enabled = { type = "boolean", optional = true },
          target = {
            type = "any",
            optional = true,
            validate = function(v)
              if type(v) ~= "string" and type(v) ~= "number" then
                return false, "must be a string or number"
              end
              return true
            end,
          },
        },
      },
    },
  },
  ui = {
    type = "struct",
    optional = true,
    fields = {
      layout = { type = "enum", optional = true, choices = { "vertical", "horizontal", "float", "buffer" } },
      start_in_insert_mode = { type = "boolean", optional = true },
      spinner_delay_ms = { type = "integer", optional = true, validate = nonneg_int },
      show_reasoning = { type = "boolean", optional = true },
      fold_reasoning = { type = "boolean", optional = true },
    },
  },
  skills = {
    type = "struct",
    optional = true,
    fields = {
      global_enabled = { type = "boolean", optional = true },
      project_enabled = { type = "boolean", optional = true },
    },
  },
  mcp = {
    type = "struct",
    optional = true,
    fields = {
      project_servers = { type = "boolean", optional = true },
      request_timeout_ms = { type = "integer", optional = true, validate = positive_int },
      auto_start = { type = "boolean", optional = true },
    },
  },
  status = {
    type = "struct",
    optional = true,
    fields = {
      lualine = { type = "boolean", optional = true },
      billing = { type = "boolean", optional = true },
    },
  },
  extensions = { type = "map", optional = true },
}
-- Valid core keys allowed in `.maxa/runtime.yaml` (schema key order).
M.CORE_KEYS = M.runtime_schema

--- Keys that, if found in a non-`extensions` position with a literal scalar value, are
--- treated as credential material and rejected fail-closed. Credentials may only enter
--- indirectly by *name* through `api_key_env` (validated against `ENV_NAME_PATTERN`);
--- a literal secret in the config is always an error. Not a security boundary by
--- itself — it is a fail-closed noise guard for the snapshot which has no
--- secret-bearing fields.
M.SECRET_KEYS = {
  api_key = true,
  apikey = true,
  token = true,
  secret = true,
  password = true,
  access_key = true,
}

--- FNV-1a 32-bit content hash (deterministic; same input -> same hash across runs).
--- Uses the LuaJIT `bit` library for the XOR step (nvim 0.11 runs LuaJIT). The hash is
--- only an evidence fingerprint, not a security primitive.
---@param s string
---@return string
local function fnv1a(s)
  local h = 2166136261
  for i = 1, #s do
    local byte = s:byte(i, i)
    h = bit.bxor(h, byte)
    -- multiply by 16777619 mod 2^32
    h = (h * 16777619) % 4294967296
  end
  return ("%08x"):format(h)
end

--- Recursively read-only-freeze a plain table so a loaded snapshot cannot be mutated
--- after creation. Returns a **proxy** with no raw keys: every read forwards to the real
--- (frozen) value through `__index`, and every write raises through `__newindex`. Because
--- the proxy stores no raw keys, writes to *existing* config keys (which otherwise bypass
--- `__newindex`) are equally rejected. Nested tables are lazily frozen on access.
---
--- The proxy also records `__maxa_real = t` so `M.unfreeze` can recover the real data
--- tree. This is required because `vim.tbl_*` helpers and `next()` iterate raw keys and
--- therefore see an empty proxy; only `__index`-style direct reads (and `pairs()` via
--- `__pairs`) work on proxies. Real-tree consumers (e.g. `resolve_provider`) must read
--- through `M.unfreeze` for consistent indexing/iteration/counting.
---@param t table plain real value (never mutated after this call)
---@return table frozen read-only proxy
function M.freeze(t)
  if type(t) ~= "table" then
    return t
  end
  return setmetatable({}, {
    __maxa_frozen = true,
    __maxa_real = t,
    __index = function(_, k)
      local v = t[k]
      if type(v) == "table" then
        return M.freeze(v)
      end
      return v
    end,
    __newindex = function(_, k)
      error("config: snapshot is immutable (fail-closed policy)", 2)
    end,
    __pairs = function()
      return next, t, nil
    end,
  })
end

--- Recover the real (unwrapped) value behind a frozen snapshot proxy. Nested values of
--- the returned tree are plain tables (freeze only lazily wraps on `__index` access), so
--- indexing, `pairs` and `vim.tbl_*` counting all agree after one unfreeze. Non-proxy
--- values (including plain caller tables) pass through unchanged; callers treat the
--- result as read-only — the snapshot itself stays immutable.
---@param v any frozen proxy or plain value
---@return any real value
function M.unfreeze(v)
  if type(v) ~= "table" then
    return v
  end
  local mt = getmetatable(v)
  if mt and mt.__maxa_real then
    return mt.__maxa_real
  end
  return v
end

--- Build a typed error object (schema contract §4.6).
---@param code string one of schema.ERROR.*
---@param message string detail
---@param cause? table|nil low-level cause
---@return table error
function M.error(code, message, cause)
  return schema.new_error(code, message, cause)
end

--- Resolve a config key from the raw parsed table; used by `load` before freezing.
--- Kept separate from the frozen-snapshot `get` so validation never reads a frozen view.
local function raw_get(raw, key)
  if type(raw) ~= "table" then
    return nil
  end
  if key == nil then
    return raw
  end
  if type(key) == "string" and key:find("%.") then
    local cur = raw
    for part in key:gmatch("[^.]+") do
      if type(cur) ~= "table" then
        return nil
      end
      cur = cur[part]
    end
    return cur
  end
  return raw[key]
end

--- Locate the project root by walking upward from a starting directory looking for the
--- `.maxa/runtime.yaml` marker.
---@param start string absolute directory to begin walking (usually the CWD)
---@return string|nil project_root absolute path to the project containing the marker
---@return string|nil err descriptive failure (nil when a root is found)
---@return string|nil found_yaml absolute path to the found `.maxa/runtime.yaml` (nil when not found)
function M.find_project_root(start)
  if type(start) ~= "string" or start == "" then
    return nil, "config.find_project_root: start directory must be a non-empty string", nil
  end
  local found = Path.new(start):find_upwards(M.RUNTIME_YAML)
  if not found then
    return nil,
      ("config.find_project_root: no '%s' found under %q; fail-closed (no default/fallback project root)"):format(
        M.RUNTIME_YAML,
        start
      ),
      nil
  end
  -- `found` is <project_root>/.maxa/runtime.yaml; project root is the dir that *contains*
  -- the `.maxa/` marker directory, i.e. two levels up from the yaml file.
  local maxa_dir = found:parent()
  local root = maxa_dir:parent():absolute()
  return root, nil, tostring(found) -- Path.__tostring yields the absolute path
end

--- Recursively walk a parsed table looking for literal secret values under the declared
--- secret keys. `extensions` is namespaced and forward-compatible, so secret keys under
--- it are still checked (defense in depth). Returns the offending dotted path or nil.
---@param node table
---@param path string dotted path for diagnostics
---@return string? offending_path
local function find_secret(node, path)
  if type(node) ~= "table" then
    return nil
  end
  for k, v in pairs(node) do
    if type(k) == "string" and M.SECRET_KEYS[k] and type(v) == "string" and v ~= "" then
      return (path == "" and k or (path .. "." .. k))
    end
    if type(v) == "table" then
      local found = find_secret(v, path == "" and tostring(k) or (path .. "." .. tostring(k)))
      if found then
        return found
      end
    end
  end
  return nil
end

--- TinyYaml decodes YAML `null`/`~` scalars to its `yaml.null` marker (a Null-class
--- instance whose `tostring` is "yaml.null"; see config/yaml.lua contract notes), so
--- scalar-typed fields carrying the marker mean "absent". Frozen snapshot proxies
--- (M.freeze) have no raw keys and therefore look empty to `next`/`vim.tbl_isempty`;
--- they are real values and must never count as null.
---@param v any
---@return boolean
local function is_null_marker(v)
  if type(v) ~= "table" then
    return false
  end
  -- tinyyaml null marker: Null-class instance (tostring == "yaml.null").
  local mt = getmetatable(v)
  if mt and mt.__tostring and tostring(v) == "yaml.null" then
    return true
  end
  -- Legacy empty-table marker fallback; frozen proxies are real values.
  if vim.tbl_isempty(v) then
    return not (mt and mt.__maxa_frozen)
  end
  return false
end

--- Recursively validate a value against a (possibly composite) field definition.
--- Errors are keyed by dotted path (`provider.definitions.deepseek-chat.protocol`).
---@param field table field definition (scalar types delegate to schema.validate_field)
---@param value any parsed value (may be a tinyyaml null marker = empty table)
---@param prefix string dotted path prefix for error keys
---@param errors table<string,string> accumulating error map
local function validate_value(field, value, prefix, errors)
  -- Normalize tinyyaml null markers to nil for scalar-typed fields; empty tables stay
  -- meaningful for map/struct fields (empty map / empty struct are valid).
  if is_null_marker(value) and field.type ~= "map" and field.type ~= "struct" then
    value = nil
  end
  if value == nil then
    if not field.optional then
      errors[prefix] = "required field is missing"
    end
    return
  end
  if field.type == "struct" then
    if type(value) ~= "table" or (not vim.tbl_isempty(value) and islist(value)) then
      errors[prefix] = "must be a mapping"
      return
    end
    for k in pairs(value) do
      if type(k) ~= "string" or field.fields[k] == nil then
        errors[prefix .. "." .. tostring(k)] = "unknown field (fail-closed)"
      end
    end
    for k, sub in pairs(field.fields) do
      validate_value(sub, value[k], prefix .. "." .. k, errors)
    end
    return
  elseif field.type == "map" then
    if type(value) ~= "table" or (not vim.tbl_isempty(value) and islist(value)) then
      errors[prefix] = "must be a mapping"
      return
    end
    if field.values then
      for k, v in pairs(value) do
        validate_value(field.values, v, prefix .. "." .. tostring(k), errors)
      end
    end
    return
  elseif field.type == "any" then
    if type(value) == "table" then
      errors[prefix] = "must be a scalar"
      return
    end
    if field.validate then
      local ok, custom = field.validate(value)
      if not ok then
        errors[prefix] = (type(custom) == "string" and custom) or "invalid value"
      end
    end
    return
  end
  local valid, err = schema.validate_field(field, value)
  if not valid then
    errors[prefix] = err or ("Not a valid %s"):format(tostring(field.type))
  end
end

--- Validate a full schema tree (struct/map-with-values/any + scalar fallback).
---@param schema_def table keys -> field definitions
---@param data table value map
---@return nil|table<string,string> nil on success, or dotted-path -> error map
function M.validate_schema(schema_def, data)
  local errors = {}
  for k, field in pairs(schema_def) do
    validate_value(field, data and data[k], tostring(k), errors)
  end
  if next(errors) then
    return errors
  end
  return nil
end

--- Cross-field provider checks that run after structural validation:
---   * a present `provider` block must name a `default` that exists in `definitions`;
---   * every definition's declared `capabilities` must not disable a protocol-native
---     channel (provider-contract capability matrix).
---@param provider any parsed provider block (may be a tinyyaml null marker)
---@return table<string,string> dotted-path -> error map (empty on success)
local function check_provider_cross_fields(provider)
  local errors = {}
  if provider == nil or is_null_marker(provider) then
    return errors
  end
  local defs = provider.definitions or {}
  if type(defs) ~= "table" or vim.tbl_isempty(defs) then
    errors["provider.definitions"] = "must be a non-empty mapping when the provider block is present"
    return errors
  end
  if type(provider.default) ~= "string" or provider.default == "" then
    errors["provider.default"] = "required when the provider block is present (must name a definitions entry)"
  elseif defs[provider.default] == nil then
    errors["provider.default"] = ("%q is not defined in provider.definitions"):format(tostring(provider.default))
  end
  for id, def in pairs(defs) do
    if type(def) == "table" and type(def.protocol) == "string" and type(def.capabilities) == "table" then
      local native = M.PROTOCOL_NATIVE[def.protocol] or {}
      for cap, declared in pairs(def.capabilities) do
        if native[cap] and declared == false then
          errors[("provider.definitions.%s.capabilities.%s"):format(tostring(id), tostring(cap))] = ("conflict: %q always provides %q; declaring false is invalid (protocol capability matrix)"):format(
            def.protocol,
            cap
          )
        end
      end
    end
  end
  return errors
end

--- A loaded config snapshot. Wrap the raw validated data in a frozen view plus the
--- evidence record; immutable thereafter.
----------------------------------------------------------------------------------------
local Snapshot = {}
Snapshot.__index = Snapshot

function Snapshot:get(key)
  if key == nil then
    return self._view
  end
  return raw_get(self._view, key)
end

function Snapshot:data()
  return self._view
end

function Snapshot:source()
  return self._evidence
end

function Snapshot:to_debug()
  return { data = self._view, source = self._evidence }
end

--- Load and freeze `.maxa/runtime.yaml` for a resolved project root.
---
--- Returns a `Snapshot` on success, or `nil, error` on any failure (missing file, YAML
--- malformed, schema invalid, unknown core field, provider cross-field violation, or
--- literal secret). Never falls back to the development mother repository's `.supermax/`.
---@param project_root string resolved project root (use find_project_root first, or pass
---   the caller's CWD and let this function resolve it).
---@param opts? table { resolve_root = boolean } when true (default), treat `project_root`
---   as a starting point and resolve upward via `find_project_root`.
---@return table|nil snapshot
---@return table|nil err typed error (schema.new_error) on failure
function M.load(project_root, opts)
  opts = opts or {}
  local root = project_root
  local found_yaml
  if opts.resolve_root ~= false then
    local r, rerr, fy = M.find_project_root(project_root)
    if not r then
      return nil, M.error(schema.ERROR.INVALID_ARGUMENT, rerr)
    end
    root = r
    found_yaml = fy
  else
    found_yaml = root .. "/" .. M.RUNTIME_YAML
  end
  local stat = vim.uv.fs_stat(found_yaml)
  if not stat or stat.type ~= "file" then
    return nil,
      M.error(
        schema.ERROR.INVALID_ARGUMENT,
        ("config.load: missing configuration file %q (fail-closed; .supermax/ is never used)"):format(found_yaml)
      )
  end
  local fh = assert(io.open(found_yaml, "rb"))
  local body = fh:read("*a")
  fh:close()
  if type(body) ~= "string" or body == "" then
    return nil, M.error(schema.ERROR.INVALID_ARGUMENT, "config.load: empty or unreadable .maxa/runtime.yaml")
  end

  -- Decode (fail-closed: nil + err means malformed YAML).
  local ok_yml, data = pcall(yaml.decode, body)
  if not ok_yml then
    return nil,
      M.error(schema.ERROR.PROTOCOL, "config.load: yaml decode error -- " .. tostring(data), { path = found_yaml })
  end
  if data == nil and ok_yml then
    return nil, M.error(schema.ERROR.PROTOCOL, "config.load: yaml decode failed (nil)", { path = found_yaml })
  end
  if type(data) ~= "table" then
    return nil,
      M.error(schema.ERROR.PROTOCOL, "config.load: .maxa/runtime.yaml must decode to a mapping", { path = found_yaml })
  end

  -- Unknown core fields (fail-closed): only schema keys + `extensions` are allowed.
  local unknown = {}
  for k in pairs(data) do
    if type(k) == "string" and M.runtime_schema[k] == nil then
      unknown[#unknown + 1] = k
    end
  end
  if #unknown > 0 then
    table.sort(unknown)
    return nil,
      M.error(
        schema.ERROR.PROTOCOL,
        ("config.load: unknown core field(s) in %q: %s (fail-closed; allowed: schema_version/project_id/provider/history/orchestrator/ui/skills/mcp/status/extensions)"):format(
          found_yaml,
          table.concat(unknown, ", ")
        ),
        { path = found_yaml, unknown = unknown }
      )
  end

  -- Credential guard (fail-closed; credentials only ever enter by name, never as literals).
  local secret_path = find_secret(data, "")
  if secret_path then
    return nil,
      M.error(
        schema.ERROR.PROTOCOL,
        ("config.load: literal credential value detected at %q; credentials must be supplied only via read-only env vars referenced by name"):format(
          secret_path
        ),
        { path = found_yaml, secret_path = secret_path }
      )
  end

  -- Structural schema validation (recursive: struct/map-values/any + scalar types).
  local verr = M.validate_schema(M.runtime_schema, data)
  if verr then
    return nil,
      M.error(
        schema.ERROR.PROTOCOL,
        "config.load: invalid .maxa/runtime.yaml -- " .. vim.inspect(verr),
        { path = found_yaml }
      )
  end

  -- Cross-field provider checks (default existence + protocol capability matrix).
  local xerr = check_provider_cross_fields(data.provider)
  if next(xerr) then
    return nil,
      M.error(
        schema.ERROR.PROTOCOL,
        "config.load: invalid .maxa/runtime.yaml -- " .. vim.inspect(xerr),
        { path = found_yaml }
      )
  end

  local evidence = {
    source = M.RUNTIME_YAML,
    config_path = found_yaml,
    project_root = root,
    content_hash = fnv1a(body),
    schema_version = data.schema_version,
    loaded_at = os.time(),
  }

  local snap = setmetatable({}, Snapshot)
  snap._view = M.freeze(data)
  snap._evidence = evidence
  snap._config_path = found_yaml
  return snap, nil
end

--- Convenience: `get(snapshot, key)` top-level helper mirroring the instance method.
---@param snapshot table a Snapshot returned by M.load
---@param key string|nil dotted key (`.` for nested) or nil for the whole data
---@return any
function M.get(snapshot, key)
  if type(snapshot) ~= "table" or not snapshot.get then
    return nil
  end
  return snapshot:get(key)
end

--- Normalize a provider base_url: strip trailing slashes (aligns with the gateway
--- factory behavior in `~/.config/nvim/lua/plugins/ai.lua` `normalize_gateway_base_url`).
---@param url string
---@return string
function M.normalize_base_url(url)
  return tostring(url or ""):gsub("/+$", "")
end

--- Resolve a provider definition into a normalized runtime record.
---
--- Reads from either a `Snapshot` (returned by M.load) or a raw validated table. The
--- snapshot itself is never mutated and never contains credential values; the resolved
--- env key value is fetched at call time and lives only in the returned record.
---
---@param config table Snapshot (or raw validated config data)
---@param id? string provider id; defaults to `provider.default`
---@return table|nil record normalized provider record
---@return table|nil err typed error (schema.new_error) on failure
function M.resolve_provider(config, id)
  local data = config
  if type(config) == "table" and config.get then
    data = config:get(nil)
  end
  -- Unwrap frozen proxies once: vim.tbl_isempty/tbl_keys/tbl_count and pairs must see
  -- the real tree, otherwise provider.definitions looks empty (raw next() over a proxy).
  data = M.unfreeze(data)
  local provider = data and data.provider
  if provider == nil or is_null_marker(provider) then
    return nil,
      M.error(
        schema.ERROR.INVALID_ARGUMENT,
        "config.resolve_provider: no provider block configured (need .maxa/runtime.yaml provider{default, definitions})"
      )
  end
  local defs = provider.definitions
  if type(defs) ~= "table" or vim.tbl_isempty(defs) then
    return nil, M.error(schema.ERROR.INVALID_ARGUMENT, "config.resolve_provider: provider.definitions is empty")
  end
  local pid = id or provider.default
  if type(pid) ~= "string" or pid == "" then
    return nil,
      M.error(
        schema.ERROR.INVALID_ARGUMENT,
        "config.resolve_provider: no provider id given and provider.default is unset"
      )
  end
  local def = defs[pid]
  if not def then
    local known = vim.tbl_keys(defs)
    table.sort(known)
    return nil,
      M.error(
        schema.ERROR.INVALID_ARGUMENT,
        ("config.resolve_provider: unknown provider %q (defined: %s)"):format(pid, table.concat(known, ", "))
      )
  end

  -- Merge protocol defaults with declared capabilities (declared wins).
  local capabilities = {}
  for k, v in pairs(M.PROTOCOL_DEFAULTS[def.protocol] or {}) do
    capabilities[k] = v
  end
  for k, v in pairs(def.capabilities or {}) do
    capabilities[k] = v
  end

  -- Normalize request options (tinyyaml null markers -> nil).
  -- NOTE: never use `cond and nil or v` here — Lua evaluates `nil or v` to `v`,
  -- so a true null marker would be kept. Use an explicit branch.
  local request = {}
  for k, v in pairs(def.request or {}) do
    if is_null_marker(v) then
      request[k] = nil
    else
      request[k] = v
    end
  end

  local record = {
    id = pid,
    protocol = def.protocol,
    base_url = M.normalize_base_url(def.base_url),
    api_key_env = def.api_key_env,
    -- Resolved at call time; never persisted, never part of the snapshot.
    api_key = def.api_key_env and os.getenv(def.api_key_env) or nil,
    model = def.model,
    capabilities = capabilities,
    request = request,
    adapter = nil,
  }

  -- Bind the protocol adapter when the registry has one registered for this protocol.
  -- Real adapters register in W4-W7 (`protocol.register_adapter`); until then the
  -- record carries a nil adapter and callers can bind later via `record:bind()`.
  local ok, proto = pcall(require, "maxa.runtime.protocol")
  if ok and type(proto) == "table" and type(proto.get_adapter) == "function" then
    record.adapter = proto.get_adapter(def.protocol)
  end
  record.bind = function(self, adapter_instance)
    record.adapter = adapter_instance
    return record
  end
  return record, nil
end

M.Snapshot = Snapshot
return M
