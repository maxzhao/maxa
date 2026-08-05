-- filepath: lua/maxa/runtime/skills/loader.lua
--- maxa runtime Skill loader (phase-3 W5).
---
--- Loads a requested Skill together with its dependency closure in
--- dependency-topological order (dependencies always activate before the
--- requesting Skill). Contract (mcp-skill-runtime spec §Skill discovery and
--- load):
---   * cycles and missing dependencies fail BEFORE partial requested-Skill
---     activation -- a failed load mutates no loader state;
---   * successful loads are deduplicated per session (loader instance) while
---     preserving the provenance of the first load (root kind + root path +
---     skill file);
---   * loading exposes sanitized instruction context (metadata + body read by
---     the discover instance); it NEVER executes project code merely because a
---     directory exists. Lua hook files are explicit declared artifacts whose
---     execution is governed by the W6 load/scope machinery.
---
--- A loader instance is session-scoped: create one per session
--- (`loader.new({ discover = ... })`) so dedup state is per-session.
---
--- W8 (phase-3): optional skill tool registration. When `loader.new` receives a
--- `tool_registry` (a `maxa.runtime.tools.registry` instance), every activated
--- skill's declared tools are registered into it. Convention:
--- `skills/<skill>/tools/<name>.lua` returns a definition table
--- `{ description, input_schema, execution?, result?, run = fun(args, ctx) }`
--- and the tool id is `<skill>/<name>` (matching the registry's server-id/tool
--- form for top-level skill ids). Registration runs for the full dependency
--- closure in activation order; failures are per-skill diagnostics (non-fatal,
--- tools are an additive capability surface) exposed through
--- `loader:tool_diagnostics(id)`. `loader:unload(id)` unregisters the skill's
--- tools and removes it from the loaded set (dependencies stay loaded).
---
--- Dependencies: `maxa.runtime.schema` (typed errors),
--- `maxa.runtime.skills.discover`. Never loads `codecompanion.*` / `mcphub.*`
--- / `lua/util/hooks/*`.

local schema = require("maxa.runtime.schema")

local M = {}

M.name = "skills.loader"
M.VERSION = 1

--- Create a session-scoped loader.
---@param opts table
---   discover = table     a `skills.discover` instance (required)
---   tool_registry = table|nil  W8: a tools.registry instance; when present,
---     activated skills register their `tools/*.lua` declarations into it
---   session_id = string|nil  optional diagnostic label
---@return table l
function M.new(opts)
  assert(type(opts) == "table" and opts.discover ~= nil, "skills.loader.new: opts.discover is required")
  local l = {
    discover = opts.discover,
    loaded = {}, -- id -> loaded record (dedup, first-load provenance)
    loaded_order = {}, -- list of loaded ids in activation order
    session_id = opts.session_id, -- optional diagnostic label
    tool_registry = opts.tool_registry, -- W8: optional tool registry seam (nil = registration disabled)
    _registered_tools = {}, -- skill id -> { [tool_id] = true } (W8 unload bookkeeping)
    _tool_diagnostics = {}, -- skill id -> string[] (W8 registration failures, non-fatal)
  }
  local self = setmetatable({}, { __index = l })

  --- Load one skill id atomically with its dependency closure.
  --- On success: every dependency (and the skill itself) becomes loaded in
  --- topological order; the requested skill record is returned. On failure:
  --- nothing is activated and loader state is unchanged.
  ---@param id string stable relative skill id
  ---@return table|nil record requested skill record
  ---@return table|nil err typed error (schema.ERROR.*)
  function self.load(id)
    if type(id) ~= "string" or id == "" then
      return nil, schema.new_error(schema.ERROR.INVALID_ARGUMENT, "skills.loader: empty skill id")
    end
    if l.loaded[id] then
      return l.loaded[id], nil -- per-session dedup; provenance preserved
    end

    local order = {} -- records in activation order (deps first)
    local visiting = {} -- DFS stack (cycle detection)
    local stack = {} -- ordered visiting stack (cycle path diagnostic)
    local visited = {} -- fully expanded ids

    ---@param skill_id string
    ---@return table|nil err
    local function visit(skill_id)
      if visited[skill_id] or l.loaded[skill_id] then
        return nil -- already loaded (this session) or expanded in this plan
      end
      if visiting[skill_id] then
        -- Build the cycle path: from the first stack occurrence to the end.
        local path = {}
        local seen = false
        for _, pid in ipairs(stack) do
          if pid == skill_id then
            seen = true
          end
          if seen then
            path[#path + 1] = pid
          end
        end
        path[#path + 1] = skill_id -- close the loop
        return schema.new_error(
          schema.ERROR.CONFIGURATION,
          ("skills.loader: dependency cycle detected while loading %q (cycle: %s)"):format(
            id,
            table.concat(path, " -> ")
          )
        )
      end

      local record, err = self.discover.resolve(skill_id)
      if not record then
        if skill_id == id then
          -- The requested skill itself cannot be resolved: propagate the
          -- discover error unchanged (unknown -> INVALID_ARGUMENT,
          -- broken metadata -> CONFIGURATION).
          return err
        end
        return schema.new_error(
          schema.ERROR.CONFIGURATION,
          ("skills.loader: skill %q (dependency of %q) cannot be resolved: %s"):format(
            skill_id,
            id,
            err and err.message or tostring(err)
          ),
          err
        )
      end

      visiting[skill_id] = true
      stack[#stack + 1] = skill_id
      local deps = record.metadata.dependencies or {}
      for _, dep in ipairs(deps) do
        local derr = visit(dep)
        if derr then
          stack[#stack] = nil
          visiting[skill_id] = nil
          return derr
        end
      end
      stack[#stack] = nil
      visiting[skill_id] = nil
      visited[skill_id] = true
      order[#order + 1] = record
      return nil
    end

    local err = visit(id)
    if err then
      return nil, err -- atomic: no partial activation on failure
    end

    -- Activate the planned records (all-or-nothing already guaranteed).
    for _, record in ipairs(order) do
      l.loaded[record.id] = record
      l.loaded_order[#l.loaded_order + 1] = record.id
      -- W8: register the skill's declared tools (dependency closure too, in
      -- activation order). Failures are diagnostics; activation never fails on
      -- tool registration.
      self:_register_skill_tools(record)
    end
    return l.loaded[id], nil
  end

  --- W8: scan `<skill_dir>/tools/*.lua` and register each declared tool into
  --- the bound tool registry. Convention: `tools/<name>.lua` returns a table
  --- `{ description, input_schema, execution?, result?, run = fun(args, ctx) }`
  --- and the registered id is `<skill_id>/<name>` (the registry's
  --- server-id/tool-name form; subskill ids containing `/` produce a deeper id
  --- which the registry rejects — recorded as a diagnostic). A broken tool
  --- file or a rejected registration never fails the skill activation: it is
  --- recorded per-skill and exposed via `tool_diagnostics(id)`.
  ---@param record table loaded skill record (id/dir)
  function self:_register_skill_tools(record)
    if not l.tool_registry or not record or type(record.dir) ~= "string" then
      return
    end
    local tools_dir = record.dir .. "/tools"
    if not vim.uv.fs_stat(tools_dir) then
      return -- the skill declares no tools
    end
    local files = vim.fn.glob(tools_dir .. "/*.lua", false, true)
    table.sort(files)
    local diag = l._tool_diagnostics[record.id] or {}
    for _, path in ipairs(files) do
      local name = path:match("([^/]+)%.lua$")
      if name and name ~= "" then
        local ok, mod = pcall(dofile, path)
        if not ok or type(mod) ~= "table" then
          diag[#diag + 1] = ("skill %q tool %q failed to load: %s"):format(
            record.id,
            name,
            ok and "module must return a table" or tostring(mod)
          )
        else
          local id = record.id .. "/" .. name
          local def = {
            id = id,
            name = name,
            description = type(mod.description) == "string" and mod.description or "",
            input_schema = mod.input_schema or { type = "object", properties = {} },
            execution = mod.execution,
            result = mod.result,
            run = function(args, ctx)
              if type(mod.run) == "function" then
                return mod.run(args, ctx)
              end
              error(("skill tool %s has no run function"):format(id), 0)
            end,
          }
          local registered, rerr = l.tool_registry:register(def)
          if not registered then
            diag[#diag + 1] = ("skill %q tool %q registration failed: %s"):format(
              record.id,
              name,
              rerr and rerr.message or "registration rejected"
            )
          else
            l._registered_tools[record.id] = l._registered_tools[record.id] or {}
            l._registered_tools[record.id][registered.id] = true
          end
        end
      end
    end
    l._tool_diagnostics[record.id] = diag
  end

  --- W8: unload one skill: unregister its declared tools from the bound tool
  --- registry and remove it from the loaded set. Dependencies loaded for this
  --- skill stay loaded (they may serve other skills); their tools stay
  --- registered. A subsequent `load` of the same id re-registers the tools.
  --- Idempotent: unknown/not-loaded ids are a no-op.
  ---@param id string stable relative skill id
  ---@return boolean unloaded true when the skill was loaded and got unloaded
  function self.unload(id)
    if type(id) ~= "string" or not l.loaded[id] then
      return false
    end
    local tools = l._registered_tools[id]
    if tools and l.tool_registry then
      for tool_id in pairs(tools) do
        l.tool_registry:unregister(tool_id)
      end
    end
    l._registered_tools[id] = nil
    l.loaded[id] = nil
    for i, lid in ipairs(l.loaded_order) do
      if lid == id then
        table.remove(l.loaded_order, i)
        break
      end
    end
    return true
  end

  --- W8: per-skill tool registration diagnostics (non-fatal). With no id,
  --- returns every skill's diagnostic list.
  ---@param id string|nil skill id (nil = all)
  ---@return table[]|table string[] for one id; id -> string[] for all
  function self.tool_diagnostics(id)
    if type(id) == "string" then
      return l._tool_diagnostics[id] or {}
    end
    return l._tool_diagnostics
  end

  --- Load several skill ids sequentially. Each individual load is atomic; a
  --- failing id returns nil plus its typed error and does not activate that
  --- id's closure (skills activated by earlier ids stay loaded).
  ---@param ids string[]
  ---@return table[]|nil records
  ---@return table|nil err
  function self.load_many(ids)
    local records = {}
    for _, id in ipairs(ids) do
      local record, err = self.load(id)
      if not record then
        return nil, err
      end
      records[#records + 1] = record
    end
    return records, nil
  end

  --- All loaded skill ids in activation order.
  ---@return string[]
  function self.list()
    local out = {}
    for i, id in ipairs(l.loaded_order) do
      out[i] = id
    end
    return out
  end

  ---@param id string
  ---@return boolean
  function self.is_loaded(id)
    return l.loaded[id] ~= nil
  end

  --- Loaded record for an id (nil when not loaded).
  ---@param id string
  ---@return table|nil
  function self.record(id)
    return l.loaded[id]
  end

  return self
end

return M
