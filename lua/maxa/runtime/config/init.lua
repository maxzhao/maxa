-- filepath: lua/maxa/runtime/config/init.lua
--- maxa runtime project configuration skeleton (phase-0 minimal scope).
---
--- Delivers, per `.supermax/drafts/phase0-development-plan.md` §5.3 / §4.8:
---   * project-root binding : walks upward from the caller's working directory looking
---     for a `.maxa/runtime.yaml` marker; if none is found it fails closed (no fallback
---     to the development mother repository's `.supermax/`).
---   * immutable snapshot   : the `.maxa/runtime.yaml` file is read once, validated,
---     and frozen into a read-only snapshot; later reads (`get`) never re-parse.
---   * fail-closed parsing  : unknown *core* fields are validation errors; credentials
---     never enter the snapshot (only the names of read-only env vars are allowed, per
---     `api_key_env`; a literal secret value is rejected). `.supermax/` is never a
---     runtime configuration source.
---   * evidence             : each snapshot records its `source` (resolved path,
---     project root, content hash, schema version) for reproducibility and audit.
---
--- Upstream alignment (read-only, never copied): `codecompanion/config.lua`
--- (`config.interactions.chat.*`) + `Chat:new` args + `schema.lua`; target contract from
--- `specs/modules/supermax-configuration/spec.md` (`.maxa/` is the only project-local
--- runtime state root; `.supermax/` is never a fallback; unknown core fields fail closed;
--- `extensions` is the only declared forward-compatible escape hatch).
---
--- Dependencies: `maxa.runtime.schema` (validation + typed errors), the self-contained
--- `maxa.runtime.config.yaml` decoder, and `plenary.path` (project-root walk, plan §10.2
--- R-03; `Path:find_upwards`/`Path:parent`). It never loads
--- `codecompanion.*`/`mcphub.*`/`lua/util/hooks/*`.
----------------------------------------------------------------------------------------
local schema = require("maxa.runtime.schema")
local yaml = require("maxa.runtime.config.yaml")
local Path = require("plenary.path")

local M = {}
M.name = "config"

--- Marker file that both locates a project root and carries the runtime overrides.
M.RUNTIME_YAML = ".maxa/runtime.yaml"

--- Minimal phase-0 `runtime.yaml` schema (plan §4.8 snapshot shape).
--- `schema_version` and `project_id` are required (project identity). Provider/model/
--- prompts are overrides (absent selects bundled defaults in later phases, matching the
--- spec's override semantics). `extensions` is the only declared forward-compatible key.
--- Unknown core keys are rejected (fail-closed) by `load`, not silently ignored.
M.runtime_schema = {
  schema_version = { type = "integer", optional = false },
  project_id = { type = "string", optional = false },
  provider = { type = "string", optional = true },
  model = { type = "string", optional = true },
  prompts = { type = "map", optional = true },
  extensions = { type = "map", optional = true },
}
-- Valid core keys allowed in `.maxa/runtime.yaml` (schema key order).
M.CORE_KEYS = M.runtime_schema

--- Keys that, if found in a non-`extensions` position with a literal scalar value, are
--- treated as credential material and rejected fail-closed. Credentials may only enter
--- indirectly by *name* through `api_key_env` (a later-phase provider field); a literal
--- secret in the config is always an error. Not a security boundary by itself — it is a
--- fail-closed noise guard for the phase-0 snapshot which has no secret-bearing fields.
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
---@param t table plain real value (never mutated after this call)
---@return table frozen read-only proxy
function M.freeze(t)
  if type(t) ~= "table" then
    return t
  end
  return setmetatable({}, {
    __maxa_frozen = true,
    __index = function(_, k)
      local v = t[k]
      if type(v) == "table" then
        return M.freeze(v)
      end
      return v
    end,
    __newindex = function(_, k)
      error("config: snapshot is immutable (phase-0 fail-closed policy)", 2)
    end,
    __pairs = function()
      return next, t, nil
    end,
  })
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
--- malformed, schema invalid, unknown core field, or literal secret). Never falls back
--- to the development mother repository's `.supermax/`.
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
        ("config.load: unknown core field(s) in %q: %s (fail-closed; only schema_version/project_id/provider/model/prompts/extensions are allowed)"):format(
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

  -- Schema validation (required fields, types).
  local verr = schema.validate(M.runtime_schema, data)
  if verr then
    return nil,
      M.error(
        schema.ERROR.PROTOCOL,
        "config.load: invalid .maxa/runtime.yaml -- " .. vim.inspect(verr),
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

M.Snapshot = Snapshot
return M
