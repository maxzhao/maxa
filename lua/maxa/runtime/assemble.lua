-- filepath: lua/maxa/runtime/assemble.lua
--- maxa runtime real-path assembly (phase-3 W1 fix).
---
--- Wires the runtime's executable surfaces through the effective config in ONE
--- call (`maxa.runtime.assemble(cfg, opts)`; exported from `maxa.runtime`):
---
---   * tool_registry — a fresh `tools.registry` instance shared by MCP servers
---     and skill tools;
---   * MCP — when `cfg.mcp.enabled`: `mcp.config.load(project_root, {
---     servers_file = cfg.mcp.servers_file or ".maxa/mcp/servers.yaml" })`
---     -> `mcp.registry.new({ tool_registry, events })` -> `apply_config(cfg)`
---     (external servers start and publish their tools into the registry). A
---     missing servers file is an EMPTY configuration, never an error;
---     `.supermax/` is never consulted as a source. A structural violation or
---     a missing project root is recorded on `mcp_error` (setup stays usable);
---   * skills — when `cfg.skills.enabled`: three-root discovery (project
---     `.maxa/skills/` > config `stdpath("config")/skills` > bundled rtp
---     `skills/`), honoring the `cfg.skills.roots` switches; a session-scoped
---     `skills.loader` bound to the tool registry loads every discovered skill
---     (skill `tools/<name>.lua` declarations register as `<skill>/<name>`);
---     startup hooks register through `skills.init.setup_startup_hooks`
---     (registry identity dedup keeps them single-registration);
---   * history (W4-B) — when `cfg.history.enabled ~= false`: the Phase-4
---     history service (`history.new`) over the resolved project root
---     (`<root>/.maxa/history`; never `.supermax/`). No root -> a typed error
---     on `asm.history_error` and assembly continues (setup stays usable);
---     construction failures are also recorded non-blocking.
---
--- Returns `{ tool_registry, mcp_registry, mcp_config, mcp_error,
--- skills_state, history, history_error, errors, teardown }`. Assembly
--- failures are NON-BLOCKING: they are recorded in `errors` / `mcp_error` /
--- `history_error` and setup keeps working; only `teardown()` runs
--- deterministic cleanup (mcp stop_all + skill unloads + history dispose,
--- idempotent).
---
--- This module never loads codecompanion.* / mcphub.* / lua/util/hooks/*
--- (requires are lazy; every sub-module is part of the guarded runtime tree).
local M = {}

M.name = "assemble"

--- Resolve the project root: an explicit `opts.project_root` wins; otherwise
--- `config.find_project_root` walks upward from `opts.cwd` looking for a
--- `.maxa/` marker (never `.supermax/`).
---@param opts table assemble options
---@return string|nil root
---@return table|nil err typed error when no project marker is found
local function resolve_project_root(opts)
  if type(opts.project_root) == "string" and opts.project_root ~= "" then
    return opts.project_root, nil
  end
  local config_mod = require("maxa.runtime.config")
  return config_mod.find_project_root(opts.cwd)
end

--- Normalize an absolute directory path (resolve + strip trailing slashes),
--- used for discovery-root dedup.
---@param path string
---@return string
local function norm_path(path)
  local p = vim.fn.fnamemodify(path, ":p")
  p = p:gsub("/+$", "")
  return p
end

--- Build the skills discovery roots (highest priority first: project, config,
--- bundled), honoring the `cfg.skills.roots` switches. Roots are deduplicated
--- by normalized path (e.g. the config root and a bundled rtp match can point
--- at the same directory).
---@param cfg table effective config
---@param opts table assemble options (project_root/cwd/bundled_roots/config_root)
---@return table[] roots { { path=string, kind="project"|"config"|"bundled" }, ... }
local function build_skill_roots(cfg, opts)
  local roots_cfg = (cfg.skills and cfg.skills.roots) or {}
  local roots = {}
  local seen = {}
  local function add(path, kind)
    if type(path) ~= "string" or path == "" then
      return
    end
    local norm = norm_path(path)
    if norm == "" or seen[norm] then
      return
    end
    seen[norm] = true
    roots[#roots + 1] = { path = norm, kind = kind }
  end
  if roots_cfg.project ~= false then
    local proot, _ = resolve_project_root(opts)
    if proot then
      add(proot .. "/.maxa/skills", "project")
    end
  end
  if roots_cfg.config ~= false then
    add(opts.config_root or (vim.fn.stdpath("config") .. "/skills"), "config")
  end
  if roots_cfg.bundled ~= false then
    if type(opts.bundled_roots) == "table" then
      for _, p in ipairs(opts.bundled_roots) do
        add(p, "bundled")
      end
    else
      local matches = vim.api.nvim_get_runtime_file("skills", false) or {}
      for _, p in ipairs(matches) do
        add(p, "bundled")
      end
    end
  end
  return roots
end

--- Real-path runtime assembly (see module header).
---@param cfg table effective configuration (mcp/skills sections; see
---   `lua/maxa/init.lua` M.defaults — comments are the documentation)
---@param opts? table {
---   events?:        table|nil event bus for MCP aggregate events
---                   (default: the global maxa.runtime.events module),
---   project_root?:  string|nil explicit project root (default: resolved from
---                   `cwd` via config.find_project_root),
---   cwd?:           string|nil start dir for project-root resolution,
---   bundled_roots?: table|nil skills discovery bundled-root override (tests),
---   config_root?:   string|nil skills discovery config-root override (tests),
--- }
---@return table asm {
---   tool_registry = table,     tools registry (fresh instance),
---   mcp_registry = table|nil,  mcp server registry (nil when mcp disabled or
---                              unavailable — missing root / structural error),
---   mcp_config = table|nil,    loaded mcp servers config (EMPTY config object
---                              when the servers file is missing; nil when mcp
---                              disabled or the config failed),
---   mcp_error = table|nil,     typed error (no project root / structural
---                              violation); nil otherwise,
---   skills_state = table|nil,  { enabled=true, roots=table[], discover=table,
---                              loader=table, loaded=string[], hook_result=table }
---                              (nil when skills disabled),
---   history = table|nil,       Phase-4 history service (W4-B; nil when
---                              history disabled or no project root),
---   history_error = table|nil, typed error (no project root / construction
---                              failed); nil otherwise,
---   errors = table[],          non-blocking assembly diagnostics
---                              ({ what="mcp"|"skills"|"skills_hooks", ... }),
---   teardown = fun(): table    idempotent teardown: mcp stop_all (tools
---                              unregistered) + skill loader unloads + history
---                              dispose; returns { mcp_stopped=bool,
---                              skills_unloaded=int, history_disposed=bool,
---                              failures=table[], already?=bool },
--- }
function M.assemble(cfg, opts)
  opts = opts or {}
  local errors = {}
  local tool_registry = require("maxa.runtime.tools.registry").new()

  local asm = {
    tool_registry = tool_registry,
    mcp_registry = nil,
    mcp_config = nil,
    mcp_error = nil,
    skills_state = nil,
    history = nil, -- W4-B: Phase-4 history service (nil when disabled/no root)
    history_error = nil, -- W4-B: typed error (no project root / construction failed)
    errors = errors,
    teardown = nil,
  }

  -- -------------------------------------------------------------------------
  -- MCP assembly: servers.yaml -> config -> registry -> apply (server starts).
  -- -------------------------------------------------------------------------
  local mcp_cfg = cfg.mcp
  if mcp_cfg and mcp_cfg.enabled ~= false then
    local root, rerr = resolve_project_root(opts)
    if not root then
      -- No `.maxa/` project marker upward: nothing to load (same semantics as
      -- a missing servers file: empty configuration, never a hard error).
      asm.mcp_error = rerr
    else
      local mcp_config_mod = require("maxa.runtime.mcp.config")
      local servers_file = (type(mcp_cfg.servers_file) == "string" and mcp_cfg.servers_file ~= "")
          and mcp_cfg.servers_file
        or nil
      local loaded, lerr = mcp_config_mod.load(root, { servers_file = servers_file })
      if not loaded then
        asm.mcp_error = lerr
      else
        asm.mcp_config = loaded
        local mcp_registry_mod = require("maxa.runtime.mcp.registry")
        local events_bus = opts.events or require("maxa.runtime.events")
        local reg = mcp_registry_mod.new({ tool_registry = tool_registry, events = events_bus })
        local apply = reg:apply_config(loaded)
        for id, err in pairs(apply.errors or {}) do
          errors[#errors + 1] = { what = "mcp", id = id, err = err }
        end
        asm.mcp_registry = reg
      end
    end
  end

  -- -------------------------------------------------------------------------
  -- Skills assembly: discover -> loader (tools registered) -> startup hooks.
  -- -------------------------------------------------------------------------
  local skills_cfg = cfg.skills
  if skills_cfg and skills_cfg.enabled ~= false then
    local discover_mod = require("maxa.runtime.skills.discover")
    local loader_mod = require("maxa.runtime.skills.loader")
    local skills_init = require("maxa.runtime.skills")

    local d = discover_mod.new({ roots = build_skill_roots(cfg, opts) })
    d.scan()
    -- Load every discovered skill (dependency closure) so declared
    -- `tools/<name>.lua` definitions register into the tool registry (W8
    -- loader tool surface). Load failures are per-skill diagnostics.
    local loader = loader_mod.new({ discover = d, tool_registry = tool_registry })
    local loaded = {}
    for id in pairs(d.records()) do
      local record, lerr = loader.load(id)
      if not record then
        errors[#errors + 1] = { what = "skills", id = id, err = lerr }
      end
    end
    for _, id in ipairs(loader.list()) do
      loaded[#loaded + 1] = id
    end
    -- W6 startup hooks (registry identity dedup keeps them single-registered;
    -- scan/parse diagnostics are recorded, never fatal).
    local hook_result = skills_init.setup_startup_hooks({ discover = d })
    for _, e in ipairs(hook_result.errors or {}) do
      errors[#errors + 1] = { what = "skills_hooks", err = e }
    end
    asm.skills_state = {
      enabled = true,
      roots = d.roots,
      discover = d,
      loader = loader,
      loaded = loaded,
      hook_result = hook_result,
    }
  end

  -- -------------------------------------------------------------------------
  -- History assembly (W4-B): the Phase-4 history service over the resolved
  -- project root (`<root>/.maxa/history`; never `.supermax/`). Opt-in via
  -- `cfg.history.enabled` (default false) — the default assembly stays inert
  -- (no service construction, no subscriptions). No project root -> a typed
  -- error on `asm.history_error` and assembly continues (setup stays usable,
  -- same non-blocking semantics as MCP).
  -- -------------------------------------------------------------------------
  local history_cfg = cfg.history
  if history_cfg and history_cfg.enabled ~= false then
    local root, rerr = resolve_project_root(opts)
    if not root then
      asm.history_error = rerr
    else
      local history_mod = require("maxa.runtime.history")
      local ok_new, service = pcall(history_mod.new, {
        root = root,
        config = history_cfg,
        events = opts.events or require("maxa.runtime.events"),
      })
      if ok_new then
        asm.history = service
      else
        asm.history_error = require("maxa.runtime.schema").new_error(
          require("maxa.runtime.schema").ERROR.PERSISTENCE,
          "history assembly failed: " .. tostring(service),
          { root = root }
        )
      end
    end
  end

  -- -------------------------------------------------------------------------
  -- Teardown: mcp stop_all (capabilities/tools unregistered by server stop) +
  -- skill loader unloads (tools unregistered) + history dispose (auto-save
  -- subscriptions removed). Idempotent: the second call is a no-op returning
  -- { already = true }.
  -- -------------------------------------------------------------------------
  local torn_down = false
  asm.teardown = function()
    if torn_down then
      return { already = true }
    end
    torn_down = true
    local report = { mcp_stopped = false, skills_unloaded = 0, history_disposed = false, failures = {} }
    if asm.mcp_registry then
      local ok, terr = pcall(function()
        asm.mcp_registry:stop_all()
      end)
      report.mcp_stopped = ok
      if not ok then
        report.failures[#report.failures + 1] = { what = "mcp", error = tostring(terr) }
      end
    end
    if asm.skills_state and asm.skills_state.loader then
      -- skills.loader methods are CLOSURES over their instance state (dot-call
      -- convention: `loader.unload(id)`), so no `self` argument is passed.
      local skill_loader = asm.skills_state.loader
      for _, id in ipairs(skill_loader.list()) do
        local ok, uerr = pcall(skill_loader.unload, id)
        if ok then
          report.skills_unloaded = report.skills_unloaded + 1
        else
          report.failures[#report.failures + 1] = { what = "skills", id = id, error = tostring(uerr) }
        end
      end
    end
    -- W4-B: history service dispose (auto-save subscriptions removed; safe
    -- when the service has no listeners). Best-effort, recorded in the report.
    if asm.history and type(asm.history.dispose) == "function" then
      local okd, derr = pcall(asm.history.dispose, asm.history)
      report.history_disposed = okd
      if not okd then
        report.failures[#report.failures + 1] = { what = "history", error = tostring(derr) }
      end
    end
    return report
  end

  return asm
end

return M
