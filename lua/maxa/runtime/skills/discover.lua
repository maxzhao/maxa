-- filepath: lua/maxa/runtime/skills/discover.lua
--- maxa runtime Skill discovery (phase-3 W5).
---
--- Discovery roots, lowest to highest priority:
---   1. bundled  — maxa plugin-bundled `skills/` (every runtimepath match of
---                 the `skills/` pattern, so a future plugin install ships its
---                 own skills and the harness repo's root `skills/` is found);
---   2. config   — `stdpath("config")/skills` (user-level global skills; for
---                 the `nvim-maxa` target this is the mother repository root
---                 `skills/` because `~/.config/nvim-maxa` links to the repo);
---   3. project  — `<project-root>/.maxa/skills/` (project skills). A project
---                 Skill with the same relative ID shadows the global ones
---                 (spec: "project same-name Skills shadow global Skills").
---
--- The development mother repository's `.supermax/skills` is NEVER a discovery
--- root: `.supermax/` belongs only to this mother repository and is not a
--- target-project runtime configuration root (AGENTS.md / mcp-skill-runtime
--- spec). The completed runtime must use the target project's `.maxa/skills/`.
---
--- Names are stable relative IDs: `name` or `main-skill/subskill` (at most one
--- subskill level; deeper nesting is not a supported skill and is skipped).
---
--- Discovery reads ONLY SKILL.md metadata (frontmatter + body as sanitized
--- instruction context). Discovery/loading never executes project code merely
--- because a directory exists: Lua hooks are explicit declared files whose
--- execution is governed by the W6 load/scope machinery, not by W5 discovery.
---
--- Dependencies: `maxa.runtime.schema` (typed errors), `maxa.runtime.config`
--- (`find_project_root`), `maxa.runtime.config.yaml` (frontmatter decode).
--- Never loads `codecompanion.*` / `mcphub.*` / `lua/util/hooks/*`.

local schema = require("maxa.runtime.schema")
local config = require("maxa.runtime.config")
local yaml = require("maxa.runtime.config.yaml")

local M = {}

M.name = "skills.discover"
M.VERSION = 1

M.SKILL_FILE = "SKILL.md"
M.MAX_SUBSKILL_DEPTH = 1 -- ids are `name` or `main/sub` (one level)

--- Root kinds in priority order (index 1 = highest priority).
M.ROOT_KINDS = { "project", "config", "bundled" }

--- Allowed values for the optional `visibility` metadata field (set).
M.VISIBILITY_VALUES = { global = true, ["local"] = true }

--- Human-readable allowed values (diagnostics).
M.VISIBILITY_NAMES = "global, local"

--- Normalize an absolute directory path (resolve, strip trailing slashes).
---@param path string
---@return string
local function normalize_path(path)
  local p = vim.fn.fnamemodify(path, ":p")
  p = p:gsub("/+$", "")
  return p
end

---@param path string
---@return boolean
local function is_dir(path)
  local st = vim.uv.fs_stat(path)
  return st ~= nil and st.type == "directory"
end

---@param path string
---@return boolean
local function is_file(path)
  local st = vim.uv.fs_stat(path)
  return st ~= nil and st.type == "file"
end

--- Build the default discovery roots. Roots are ordered highest priority first
--- (project, config, bundled) and deduplicated by normalized path (a config
--- directory that is also found on the runtimepath is only registered once).
---@param opts? table
---   roots? = explicit { {path=string, kind=string}, ... } -- bypasses defaults
---   bundled_roots? table|nil -- rtp-match override (tests)
---   config_root? string|nil  -- user global override (tests)
---   project_root? string|nil -- project root override (tests)
---   cwd? string|nil          -- start dir for find_project_root (default getcwd)
---@return table[] roots ordered highest priority first
function M.default_roots(opts)
  opts = opts or {}
  local roots = {}
  local seen = {}

  local function add(path, kind)
    if type(path) ~= "string" or path == "" then
      return
    end
    local norm = normalize_path(path)
    if norm == "" or seen[norm] then
      return
    end
    seen[norm] = true
    roots[#roots + 1] = { path = norm, kind = kind }
  end

  -- Highest priority: project `.maxa/skills/`.
  local proot = opts.project_root
  if proot == nil then
    proot, _ = config.find_project_root(opts.cwd)
  end
  if proot then
    add(proot .. "/.maxa/skills", "project")
  end

  -- User-level global: `stdpath("config")/skills`.
  if opts.config_root ~= nil then
    add(opts.config_root, "config")
  else
    add(vim.fn.stdpath("config") .. "/skills", "config")
  end

  -- Bundled: every runtimepath match of `skills/`.
  if opts.bundled_roots ~= nil then
    for _, p in ipairs(opts.bundled_roots) do
      add(p, "bundled")
    end
  else
    local matches = vim.api.nvim_get_runtime_file("skills", false) or {}
    for _, p in ipairs(matches) do
      add(p, "bundled")
    end
  end

  return roots
end

--- Validate one normalized metadata field that must be a list of strings.
---@param value any raw frontmatter value
---@param field string field name for the error message
---@return table|nil list
---@return string|nil err
local function as_string_list(value, field)
  if value == nil then
    return nil, nil
  end
  if type(value) ~= "table" then
    return nil, ("metadata field %q must be a list of strings"):format(field)
  end
  for _, item in ipairs(value) do
    if type(item) ~= "string" then
      return nil, ("metadata field %q must be a list of strings"):format(field)
    end
  end
  return value, nil
end

--- Normalize raw frontmatter into the W5 metadata contract.
---@param raw table raw decoded frontmatter mapping
---@return table metadata
---@return string|nil err fail-closed validation error
function M.normalize_metadata(raw)
  if type(raw) ~= "table" then
    return nil, "SKILL.md frontmatter must decode to a mapping"
  end

  local name = raw.name
  if type(name) ~= "string" or name == "" then
    return nil, "SKILL.md metadata is missing required string field `name`"
  end
  local description = raw.description
  if type(description) ~= "string" or description == "" then
    return nil, "SKILL.md metadata is missing required string field `description`"
  end

  local triggers, terr = as_string_list(raw.triggers, "triggers")
  if terr then
    return nil, terr
  end
  local deps, derr = as_string_list(raw.dependencies, "dependencies")
  if derr then
    return nil, derr
  end
  local mcp_deps, merr = as_string_list(raw.mcp_dependencies, "mcp_dependencies")
  if merr then
    return nil, merr
  end
  local resources, rerr = as_string_list(raw.resources, "resources")
  if rerr then
    return nil, rerr
  end

  local visibility = raw.visibility
  if visibility ~= nil and (type(visibility) ~= "string" or not M.VISIBILITY_VALUES[visibility]) then
    return nil, ("metadata field %q must be one of %s"):format("visibility", M.VISIBILITY_NAMES)
  end

  -- Optional hooks/system fragments: parsed and preserved verbatim in W5.
  -- Interpretation (hook definitions, system fragments) belongs to W6; an
  -- invalid shape here does not block discovery metadata (W6 validates it).
  local hooks = raw.hooks
  local system = raw.system

  -- Extra fields are preserved as-is for forward compatibility.
  local extra = {}
  for k, v in pairs(raw) do
    if
      k ~= "name"
      and k ~= "description"
      and k ~= "triggers"
      and k ~= "dependencies"
      and k ~= "mcp_dependencies"
      and k ~= "visibility"
      and k ~= "resources"
      and k ~= "hooks"
      and k ~= "system"
    then
      extra[k] = v
    end
  end

  return {
    name = name,
    description = description,
    triggers = triggers or {},
    dependencies = deps or {},
    mcp_dependencies = mcp_deps or {},
    visibility = visibility,
    resources = resources or {},
    hooks = hooks,
    system = system,
    extra = extra,
  },
    nil
end

--- Split SKILL.md content into frontmatter text + body.
---@param content string
---@return string|nil fm_text raw frontmatter source (without the `---` fences)
---@return string|nil body markdown body after the closing fence
---@return string|nil err
local function split_frontmatter(content)
  -- Leading fenced block: ^---\n ... \n---\n (with optional CRLF). find()
  -- returns start/end positions plus captures (match() would only return the
  -- captures, losing the closing-fence position needed for the body split).
  local fm_start, fm_end, inner = content:find("^%-%-%-\r?\n(.-)\r?\n%-%-%-\r?\n")
  if not fm_start then
    -- Tolerate a final fence without a trailing newline.
    fm_start, fm_end, inner = content:find("^%-%-%-\r?\n(.-)\r?\n%-%-%-$")
  end
  if not fm_start then
    return nil, nil, "SKILL.md has no leading --- frontmatter block"
  end
  local body = content:sub(fm_end + 1)
  body = body:gsub("^[\r\n]+", "")
  return inner, body, nil
end

--- Parse a SKILL.md file into a discovery record.
---@param path string SKILL.md absolute path
---@param id string stable relative skill id
---@return table|nil record
---@return table|nil err typed error (schema.ERROR.CONFIGURATION)
function M.parse_skill_file(path, id)
  local fh = io.open(path, "rb")
  if not fh then
    return nil, schema.new_error(schema.ERROR.CONFIGURATION, ("skills.discover: cannot open %s"):format(path))
  end
  local content = fh:read("*a")
  fh:close()

  local fm_text, body, ferr = split_frontmatter(content)
  if not fm_text then
    return nil, schema.new_error(schema.ERROR.CONFIGURATION, ("skills.discover: %s: %s"):format(path, ferr))
  end

  local raw, yerr = yaml.decode(fm_text)
  if not raw then
    return nil,
      schema.new_error(
        schema.ERROR.CONFIGURATION,
        ("skills.discover: %s: frontmatter yaml: %s"):format(path, tostring(yerr))
      )
  end

  local metadata, merr = M.normalize_metadata(raw)
  if not metadata then
    return nil, schema.new_error(schema.ERROR.CONFIGURATION, ("skills.discover: %s: %s"):format(path, merr))
  end

  return {
    id = id,
    root = path:match("^(.*)/[^/]+/[^/]+$") or path,
    dir = path:match("^(.*)/SKILL%.md$"),
    file = path,
    metadata = metadata,
    frontmatter = raw,
    body = body or "",
    valid = true,
  },
    nil
end

--- Create a discovery instance.
---@param opts? table
---   roots? = explicit root records (bypasses default resolution)
---   bundled_roots? / config_root? / project_root? / cwd? -> M.default_roots
---@return table d
function M.new(opts)
  opts = opts or {}
  local d = {
    roots = opts.roots or M.default_roots(opts),
    index = {}, -- id -> valid record (highest-priority valid claim)
    claims = {}, -- id -> record (highest-priority claim, valid or invalid)
    invalid = {}, -- { id, root, dir, file, err } scan failures (diagnostics)
  }
  local self = setmetatable({}, { __index = d })

  --- Re-scan every root and rebuild the index/claims. Shadowing: for the same
  --- id, the highest-priority root wins regardless of validity (fail-closed:
  --- a broken project Skill must not silently fall back to a global one).
  ---@return table index id -> valid record
  function self.scan()
    local index, claims, invalid = {}, {}, {}
    for _, root in ipairs(d.roots) do
      if is_dir(root.path) then
        local entries = vim.fn.readdir(root.path) or {}
        table.sort(entries)
        for _, name in ipairs(entries) do
          if name:sub(1, 1) ~= "." then
            local dir1 = root.path .. "/" .. name
            local file1 = dir1 .. "/" .. M.SKILL_FILE
            if is_file(file1) then
              self._claim(root, name, dir1, file1, index, claims, invalid)
            end
            if is_dir(dir1) then
              local subs = vim.fn.readdir(dir1) or {}
              table.sort(subs)
              for _, sub in ipairs(subs) do
                if sub:sub(1, 1) ~= "." then
                  local dir2 = dir1 .. "/" .. sub
                  local file2 = dir2 .. "/" .. M.SKILL_FILE
                  if is_file(file2) then
                    self._claim(root, name .. "/" .. sub, dir2, file2, index, claims, invalid)
                  end
                  -- Deeper nesting is not a supported skill depth; skipped.
                end
              end
            end
          end
        end
      end
    end
    d.index = index
    d.claims = claims
    d.invalid = invalid
    return index
  end

  --- Internal: parse and register one skill candidate under shadow rules.
  ---@param root table root record
  ---@param id string relative id
  ---@param dir string skill directory
  ---@param file string SKILL.md path
  ---@param index table valid records
  ---@param claims table all claims
  ---@param invalid table diagnostics
  function self._claim(root, id, dir, file, index, claims, invalid)
    if claims[id] then
      return -- already claimed by a higher-priority root
    end
    local record, err = M.parse_skill_file(file, id)
    if not record then
      local bad = { id = id, root = root.path, root_kind = root.kind, dir = dir, file = file, valid = false, err = err }
      claims[id] = bad
      invalid[#invalid + 1] = bad
      return
    end
    record.root = root.path
    record.root_kind = root.kind
    claims[id] = record
    index[id] = record
  end

  --- Resolve a skill id to its highest-priority claim.
  ---@param id string stable relative id
  ---@return table|nil record
  ---@return table|nil err typed error
  function self.resolve(id)
    if type(id) ~= "string" or id == "" then
      return nil, schema.new_error(schema.ERROR.INVALID_ARGUMENT, "skills.discover: empty skill id")
    end
    local claim = d.claims[id]
    if not claim then
      return nil, schema.new_error(schema.ERROR.INVALID_ARGUMENT, ("skills.discover: unknown skill %q"):format(id))
    end
    if not claim.valid then
      local err = claim.err
      return nil,
        schema.new_error(
          schema.ERROR.CONFIGURATION,
          ("skills.discover: skill %q (%s) is invalid: %s"):format(id, claim.file, err.message or tostring(err)),
          err
        )
    end
    return claim, nil
  end

  --- All valid discovered records (id -> record).
  ---@return table
  function self.records()
    return d.index
  end

  --- Scan diagnostics (invalid candidates).
  ---@return table[]
  function self.invalid_skills()
    return d.invalid
  end

  return self
end

return M
