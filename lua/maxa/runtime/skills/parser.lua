-- filepath: lua/maxa/runtime/skills/parser.lua
--- maxa runtime SkillHook definition parser (phase-3 W6).
---
--- Parses a Skill's `hooks/{EventName}.md|.lua` files into normalized hook
--- definitions:
---   * markdown hooks carry frontmatter
---     (enabled/load(startup|on_load)/scope(global|session|cascade)/filter/
---     opts/inject_at(pre|post)/once) plus prompts parsed from `## user` /
---     `## llm` / `## system` body sections into a `{role, content}` list;
---   * lua hooks `return` a definition table
---     {load, scope, inject_at, enabled, opts, filter?, render=fun(ctx)};
---     static `prompts` in a lua hook is a validation error (render-only).
---
--- Contract (mcp-skill-runtime spec §SkillHook):
---   * md+lua definitions for the SAME event name in one Skill are a
---     validation error: the event is skipped and reported (aligned with the
---     downstream `scan_hooks` conflict semantics);
---   * every parsed hook carries a deterministic `definition_hash` over the
---     normalized definition (lua hooks additionally hash their file content,
---     so implementation changes change the identity);
---   * enabled=false skips the hook entirely (nil, no error);
---   * parsing NEVER loads `codecompanion.*` / `mcphub.*` / `lua/util/hooks/*`;
---     lua hook files are loaded with loadfile+pcall (no package caching).
---
--- Dependencies: `maxa.runtime.schema` (typed errors), `maxa.runtime.config.yaml`
--- (frontmatter decode). Never loads the legacy families.

local schema = require("maxa.runtime.schema")
local yaml = require("maxa.runtime.config.yaml")

local M = {}

M.name = "skills.parser"
M.VERSION = 1

M.HOOK_ROLES = { system = true, user = true, llm = true }
M.LOAD_VALUES = { startup = true, on_load = true }
M.SCOPE_VALUES = { global = true, session = true, cascade = true }
M.INJECT_VALUES = { pre = true, post = true }

M.TOMBSTONE_TAG = "skill_hook_tombstone"
M.INJECT_TAG = "skill_hook"

--- FNV-1a 32-bit content hash. Deterministic across runs; used for hook
--- definition identity (not cryptographic). Pure-Lua, nvim-independent.
---@param s string
---@return string
local function fnv1a(s)
  local h = 2166136261
  for i = 1, #s do
    h = bit.bxor(h, s:byte(i, i) or 0)
    h = (h * 16777619) % 4294967296
  end
  return tostring(h)
end

---@param val any
---@return string
local function json_hash(val)
  local ok, json = pcall(vim.json.encode, val)
  if not ok then
    json = tostring(val)
  end
  return fnv1a(json)
end

---@param path string
---@return string|nil content
local function read_file(path)
  local fh = io.open(path, "rb")
  if not fh then
    return nil
  end
  local content = fh:read("*a")
  fh:close()
  return content
end

--- Extract the event name from a hook file path (basename without extension).
---@param path string
---@return string
function M.extract_event_name(path)
  local filename = path:match("([^/]+)%.[^.]+$")
  return filename or ""
end

--- Split hook frontmatter (`---\n...\n---`) from the body.
---@param content string
---@return string|nil fm_text
---@return string|nil body
---@return string|nil err
local function split_frontmatter(content)
  local fm_start, fm_end, inner = content:find("^%-%-%-\r?\n(.-)\r?\n%-%-%-\r?\n")
  if not fm_start then
    fm_start, fm_end, inner = content:find("^%-%-%-\r?\n(.-)\r?\n%-%-%-$")
  end
  if not fm_start then
    return nil, nil, "no leading --- frontmatter block"
  end
  local body = content:sub(fm_end + 1)
  body = body:gsub("^[\r\n]+", "")
  return inner, body, nil
end

--- Parse the markdown body into prompt records. Sections are introduced by
--- `## user` / `## llm` / `## system` (exact heading). A body without any
--- recognized section becomes a single `system` prompt (downstream-aligned).
---@param body string
---@return table[] prompts {role, content}[]
function M.parse_prompts(body)
  local prompts = {}
  local current_role = nil
  local current_lines = {}

  local function flush()
    if not current_role then
      return
    end
    local content = table.concat(current_lines, "\n")
    content = content:gsub("^[\r\n]+", ""):gsub("[\r\n]+$", "")
    if content ~= "" then
      prompts[#prompts + 1] = { role = current_role, content = content }
    end
    current_role = nil
    current_lines = {}
  end

  for line in (body .. "\n"):gmatch("([^\n]*)\n") do
    local role = line:match("^##%s+(%w+)%s*$")
    if role and M.HOOK_ROLES[role] then
      flush()
      current_role = role
    elseif current_role then
      current_lines[#current_lines + 1] = line
    end
  end
  flush()

  if #prompts == 0 and body:gsub("^%s+", ""):gsub("%s+$", "") ~= "" then
    local content = body:gsub("^[\r\n]+", ""):gsub("[\r\n]+$", "")
    if content ~= "" then
      prompts[#prompts + 1] = { role = "system", content = content }
    end
  end
  return prompts
end

--- Count llm->user turn breaks in a prompt list (multi-turn structure
--- diagnostic; downstream emits a warning and keeps the hook, so does maxa:
--- the count is recorded on the hook record as `turn_breaks`).
---@param prompts table[]
---@return integer
local function count_turn_breaks(prompts)
  local breaks = 0
  local prev_role = nil
  for _, prompt in ipairs(prompts) do
    if prev_role == "llm" and prompt.role == "user" then
      breaks = breaks + 1
    end
    prev_role = prompt.role
  end
  return breaks
end

--- Normalize the raw frontmatter mapping into hook fields (fail-closed).
---@param raw table|nil
---@return table fields normalized {enabled, load, scope, inject_at, filter, opts}
---@return string|nil err
local function normalize_frontmatter(raw)
  if raw == nil then
    raw = {}
  end
  if type(raw) ~= "table" then
    return nil, "frontmatter must decode to a mapping"
  end

  local enabled = raw.enabled
  if enabled ~= nil and type(enabled) ~= "boolean" then
    return nil, "frontmatter field `enabled` must be a boolean"
  end

  local load = raw.load or "on_load"
  if type(load) ~= "string" or not M.LOAD_VALUES[load] then
    return nil, "frontmatter field `load` must be one of startup, on_load"
  end

  local scope = raw.scope or "global"
  if type(scope) ~= "string" or not M.SCOPE_VALUES[scope] then
    return nil, "frontmatter field `scope` must be one of global, session, cascade"
  end

  local inject_at = raw.inject_at or "post"
  if type(inject_at) ~= "string" or not M.INJECT_VALUES[inject_at] then
    return nil, "frontmatter field `inject_at` must be one of pre, post"
  end

  local filter = raw.filter
  if filter ~= nil and type(filter) ~= "table" then
    return nil, "frontmatter field `filter` must be a mapping or nil"
  end

  local opts = raw.opts
  if opts == nil then
    opts = {}
  end
  if type(opts) ~= "table" then
    return nil, "frontmatter field `opts` must be a mapping or nil"
  end
  -- Top-level `once: true` is accepted and merged into opts (task contract).
  if raw.once ~= nil then
    if type(raw.once) ~= "boolean" then
      return nil, "frontmatter field `once` must be a boolean"
    end
    if opts.once == nil then
      opts = vim.deepcopy(opts)
      opts.once = raw.once
    end
  end

  return {
    -- enabled defaults to true; explicit false disables (do NOT use the
    -- `x and y or z` idiom here: false must stay false).
    enabled = enabled ~= false,
    load = load,
    scope = scope,
    inject_at = inject_at,
    filter = filter,
    opts = opts,
  },
    nil
end
--- Build the common hook record tail shared by markdown/lua hooks.
---@param kind string "markdown"|"lua"
---@param path string
---@param skill_dir string
---@param skill_id string
---@param fields table normalized frontmatter fields
---@param extra table kind-specific fields (prompts|render, file_hash)
---@return table hook
local function build_hook(kind, path, skill_dir, skill_id, fields, extra)
  local event_name = M.extract_event_name(path)
  local hook = {
    kind = kind,
    skill_id = skill_id,
    event_name = event_name,
    path = path,
    skill_dir = skill_dir,
    load = fields.load,
    scope = fields.scope,
    inject_at = fields.inject_at,
    filter = fields.filter,
    opts = fields.opts,
    priority = type(fields.opts.priority) == "number" and fields.opts.priority or 0,
    enabled = fields.enabled,
    frontmatter = fields,
    definition_hash = "",
  }
  for k, v in pairs(extra) do
    hook[k] = v
  end
  hook.definition_hash = M.definition_hash(hook)
  return hook
end

--- Normalize a hook definition into a JSON-safe canonical table used for the
--- definition hash. Lua hooks contribute a content hash of their file so an
--- implementation change alters the identity.
---@param hook table parsed hook record
---@return table def
function M.normalize_definition(hook)
  local def = {
    kind = hook.kind,
    event_name = hook.event_name,
    load = hook.load,
    scope = hook.scope,
    inject_at = hook.inject_at,
    filter = hook.filter,
    opts = hook.opts or {},
  }
  if hook.kind == "markdown" then
    def.prompts = hook.prompts
  else
    def.render = true -- marker: render is a function (file_hash covers body)
    def.file_hash = hook.file_hash
  end
  return def
end

--- Deterministic definition hash over the normalized hook definition.
---@param hook table parsed hook record
---@return string
function M.definition_hash(hook)
  return json_hash(M.normalize_definition(hook))
end

--- Parse a markdown hook file.
---@param path string absolute hook file path
---@param skill_dir string skill directory
---@param skill_id string stable relative skill id
---@return table|nil hook nil when disabled or when a validation error occurred
---@return table|nil err typed error (schema.ERROR.CONFIGURATION)
function M.parse_hook_file(path, skill_dir, skill_id)
  local content = read_file(path)
  if not content then
    return nil, schema.new_error(schema.ERROR.CONFIGURATION, ("skills.parser: cannot read hook file %s"):format(path))
  end

  local fm_text, body, ferr = split_frontmatter(content)
  if not fm_text then
    return nil, schema.new_error(schema.ERROR.CONFIGURATION, ("skills.parser: %s: %s"):format(path, ferr))
  end

  local raw, yerr = yaml.decode(fm_text)
  if not raw then
    return nil,
      schema.new_error(
        schema.ERROR.CONFIGURATION,
        ("skills.parser: %s: frontmatter yaml: %s"):format(path, tostring(yerr))
      )
  end

  local fields, nerr = normalize_frontmatter(raw)
  if not fields then
    return nil, schema.new_error(schema.ERROR.CONFIGURATION, ("skills.parser: %s: %s"):format(path, nerr))
  end
  if not fields.enabled then
    return nil, nil
  end

  local event_name = M.extract_event_name(path)
  if event_name == "" then
    return nil, schema.new_error(schema.ERROR.CONFIGURATION, ("skills.parser: invalid hook filename %s"):format(path))
  end

  local prompts = M.parse_prompts(body)
  if #prompts == 0 then
    return nil, schema.new_error(schema.ERROR.CONFIGURATION, ("skills.parser: %s: no prompts found"):format(path))
  end

  local hook = build_hook("markdown", path, skill_dir, skill_id, fields, {
    prompts = prompts,
    turn_breaks = count_turn_breaks(prompts),
  })
  return hook, nil
end

--- Parse a lua hook file: loadfile + pcall the chunk (no package caching),
--- validate the returned definition table.
---@param path string absolute hook file path
---@param skill_dir string skill directory
---@param skill_id string stable relative skill id
---@return table|nil hook nil when disabled or invalid
---@return table|nil err typed error (schema.ERROR.CONFIGURATION)
function M.parse_lua_hook_file(path, skill_dir, skill_id)
  local content = read_file(path)
  if not content then
    return nil, schema.new_error(schema.ERROR.CONFIGURATION, ("skills.parser: cannot read hook file %s"):format(path))
  end

  local chunk, lerr = loadfile(path)
  if not chunk then
    return nil,
      schema.new_error(
        schema.ERROR.CONFIGURATION,
        ("skills.parser: %s: lua load failed: %s"):format(path, tostring(lerr))
      )
  end
  local ok, spec = pcall(chunk)
  if not ok then
    return nil,
      schema.new_error(
        schema.ERROR.CONFIGURATION,
        ("skills.parser: %s: lua hook execution failed: %s"):format(path, tostring(spec))
      )
  end
  if type(spec) ~= "table" then
    return nil,
      schema.new_error(schema.ERROR.CONFIGURATION, ("skills.parser: %s: lua hook must return a table"):format(path))
  end
  if spec.enabled == false then
    return nil, nil
  end
  if spec.prompts ~= nil then
    return nil,
      schema.new_error(
        schema.ERROR.CONFIGURATION,
        ("skills.parser: %s: lua hook must not define static prompts; use render(ctx) only"):format(path)
      )
  end
  if type(spec.render) ~= "function" then
    return nil,
      schema.new_error(schema.ERROR.CONFIGURATION, ("skills.parser: %s: lua hook must define render(ctx)"):format(path))
  end

  -- Lua filters may be function predicates; the shared frontmatter normalizer
  -- only accepts table filters, so validate and re-attach after normalization.
  local lua_filter = spec.filter
  if lua_filter ~= nil and type(lua_filter) ~= "table" and type(lua_filter) ~= "function" then
    return nil,
      schema.new_error(
        schema.ERROR.CONFIGURATION,
        ("skills.parser: %s: filter must be a table, function, or nil"):format(path)
      )
  end
  local fields, ferr = normalize_frontmatter({
    enabled = spec.enabled,
    load = spec.load,
    scope = spec.scope,
    inject_at = spec.inject_at,
    filter = nil, -- lua filter re-attached below
    opts = spec.opts,
  })
  if not fields then
    return nil, schema.new_error(schema.ERROR.CONFIGURATION, ("skills.parser: %s: %s"):format(path, ferr))
  end
  fields.filter = lua_filter

  local event_name = M.extract_event_name(path)
  if event_name == "" then
    return nil, schema.new_error(schema.ERROR.CONFIGURATION, ("skills.parser: invalid hook filename %s"):format(path))
  end

  local hook = build_hook("lua", path, skill_dir, skill_id, fields, {
    render = spec.render,
    file_hash = fnv1a(content),
  })
  return hook, nil
end

--- Scan a Skill's `hooks/` directory for hook definitions.
--- md+lua definitions for the same event name are a validation error: the
--- event is skipped and reported in `errors` (downstream scan_hooks conflict
--- semantics). Parse failures are also collected in `errors`.
---@param skill_dir string skill directory
---@param skill_id string stable relative skill id
---@return table result { hooks=table[], errors=table[] }
function M.scan_hooks(skill_dir, skill_id)
  local result = { hooks = {}, errors = {} }
  local hooks_dir = skill_dir .. "/hooks"
  local handle = vim.uv.fs_scandir(hooks_dir)
  if not handle then
    return result -- no hooks dir: empty
  end

  local by_event = {}
  while true do
    local name, typ = vim.uv.fs_scandir_next(handle)
    if not name then
      break
    end
    if typ == "file" then
      local event_name, ext = name:match("^(.+)%.([^.]+)$")
      if event_name and (ext == "md" or ext == "lua") then
        by_event[event_name] = by_event[event_name] or {}
        by_event[event_name][ext] = hooks_dir .. "/" .. name
      end
    end
  end

  local event_names = {}
  for event_name in pairs(by_event) do
    event_names[#event_names + 1] = event_name
  end
  table.sort(event_names)

  for _, event_name in ipairs(event_names) do
    local files = by_event[event_name]
    if files.md and files.lua then
      result.errors[#result.errors + 1] = {
        event_name = event_name,
        reason = "conflict",
        message = ("skills.parser: conflicting hook definitions in %s: %s.md and %s.lua both exist; skipping this event hook"):format(
          hooks_dir,
          event_name,
          event_name
        ),
        files = { md = files.md, lua = files.lua },
      }
    elseif files.md then
      local hook, err = M.parse_hook_file(files.md, skill_dir, skill_id)
      if hook then
        result.hooks[#result.hooks + 1] = hook
      elseif err then
        result.errors[#result.errors + 1] =
          { event_name = event_name, reason = "parse", message = err.message, files = { md = files.md } }
      end
    elseif files.lua then
      local hook, err = M.parse_lua_hook_file(files.lua, skill_dir, skill_id)
      if hook then
        result.hooks[#result.hooks + 1] = hook
      elseif err then
        result.errors[#result.errors + 1] =
          { event_name = event_name, reason = "parse", message = err.message, files = { lua = files.lua } }
      end
    end
  end

  return result
end

return M
