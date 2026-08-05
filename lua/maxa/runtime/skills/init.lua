-- filepath: lua/maxa/runtime/skills/init.lua
--- maxa Skill subsystem (phase-0 placeholder extended by phase-3 W5/W6).
---
--- The Skill subsystem lives in the sibling modules:
---   * skills/discover.lua — three-root discovery (bundled rtp `skills/` +
---     `stdpath("config")/skills` + project `.maxa/skills/`), SKILL.md
---     metadata parsing, project-over-global shadowing, stable relative IDs
---     with one subskill level
---   * skills/loader.lua   — dependency-topological load, cycle/missing-dep
---     atomic failure, per-session dedup with provenance, W8 optional skill
---     tool registration (`tools/<name>.lua` declarations -> tool registry;
---     `loader:unload(id)` unregisters)
---   * skills/parser.lua   — hooks/{EventName}.md|.lua definition parsing
---     (frontmatter + prompts / render), md+lua conflict detection,
---     definition hashing
---   * skills/registry.lua — hook registration identity
---     (skill_id,event_name,definition_hash,scope,owner_session|global),
---     dedup, cascade parent-chain lineage, custom event names, session cleanup
---   * skills/fire.lua     — pre (sync, deterministic, injection before
---     request composition) / post (immutable observers) dispatch, pure
---     filters, once/tombstone, typed failure isolation, validation
---   * skills/injector.lua — pre-injection message construction with
---     provenance persistence, once/tombstone durability, restore_once_state
---
--- This facade stays lightweight (it must not eagerly require the heavy
--- modules) and provides the W6 assembly points:
---   * setup_startup_hooks()      — register load=startup hooks once per
---     runtime startup (dedup keeps them single-registration);
---   * register_skill_hooks()     — register a loaded skill's load=on_load
---     hooks; scope=session/cascade binds them to the loading session;
---   * restore_hooks_from_messages() — restore once state + re-register hooks
---     for a restored session.
---
--- Loading this module never loads codecompanion.* / mcphub.* /
--- lua/util/hooks/*. The development mother repository's `.supermax/skills`
--- is never a discovery root (see discover.lua).

local M = { name = "skills" }

--- Sub-module names (runtime inventory / diagnostics).
M.modules = { "discover", "loader", "parser", "registry", "fire", "injector" }

---@param name string one of M.modules
---@return any module
function M.require(name)
  assert(vim.tbl_contains(M.modules, name), ("skills.init.require: unknown sub-module %q"):format(tostring(name)))
  return require("maxa.runtime.skills." .. name)
end

-- Lazily created default instances (runtime wiring uses these; tests build
-- their own hermetic instances).
local default_registry = nil
local default_fire = nil

--- Default SkillHook registry (created on first use).
---@return table registry instance
function M.registry()
  if not default_registry then
    default_registry = require("maxa.runtime.skills.registry").new()
  end
  return default_registry
end

--- Default fire dispatcher bound to the default registry.
---@return table fire instance
function M.fire()
  if not default_fire then
    default_fire = require("maxa.runtime.skills.fire").new({ registry = M.registry() })
  end
  return default_fire
end

--- Register a Skill's startup hooks (load=startup), once per runtime startup.
--- The registry identity dedup guarantees single registration even if this is
--- called again (e.g. from a startup hook itself).
---@param opts? table {
---   discover?: table|nil discover instance (default: fresh default-roots scan),
---   registry?: table|nil registry instance (default: M.registry())
--- }
---@return table result { registered=integer, deduped=integer, errors=table[] }
function M.setup_startup_hooks(opts)
  opts = opts or {}
  local parser = require("maxa.runtime.skills.parser")
  local registry = opts.registry or M.registry()

  local discover = opts.discover
  if not discover then
    local discover_mod = require("maxa.runtime.skills.discover")
    discover = discover_mod.new()
    discover.scan()
  end

  local result = { registered = 0, deduped = 0, errors = {} }
  for _, record in pairs(discover.records()) do
    local scanned = parser.scan_hooks(record.dir, record.id)
    for _, err in ipairs(scanned.errors) do
      result.errors[#result.errors + 1] = err
    end
    for _, hook in ipairs(scanned.hooks) do
      if hook.load == "startup" then
        local owner = nil
        if hook.scope == "session" or hook.scope == "cascade" then
          result.errors[#result.errors + 1] = {
            event_name = hook.event_name,
            reason = "scope",
            message = ("skills: startup hook %s/%s must use scope=global"):format(hook.skill_id, hook.event_name),
          }
          goto continue
        end
        local res = registry.register(hook, { owner_session = owner })
        if res.ok then
          if res.deduped then
            result.deduped = result.deduped + 1
          else
            result.registered = result.registered + 1
          end
        else
          result.errors[#result.errors + 1] = {
            event_name = hook.event_name,
            reason = "register",
            message = res.err and res.err.message or "registration failed",
          }
        end
        ::continue::
      end
    end
  end
  return result
end

--- Register a loaded Skill's on_load hooks. scope=session/cascade hooks bind
--- to the loading session; scope=global hooks are unbound (identity dedup
--- keeps them registered once).
---@param record table loaded skill record (discover record: id, dir, ...)
---@param session_id string|nil loading session id (required for
---   scope=session/cascade on_load hooks)
---@param opts? table { registry?: table|nil }
---@return table result { registered=integer, deduped=integer, errors=table[] }
function M.register_skill_hooks(record, session_id, opts)
  opts = opts or {}
  local parser = require("maxa.runtime.skills.parser")
  local registry = opts.registry or M.registry()

  local result = { registered = 0, deduped = 0, errors = {} }
  local scanned = parser.scan_hooks(record.dir, record.id)
  for _, err in ipairs(scanned.errors) do
    result.errors[#result.errors + 1] = err
  end
  for _, hook in ipairs(scanned.hooks) do
    if hook.load == "on_load" then
      local owner = nil
      if hook.scope == "session" or hook.scope == "cascade" then
        if type(session_id) ~= "string" or session_id == "" then
          result.errors[#result.errors + 1] = {
            event_name = hook.event_name,
            reason = "scope",
            message = ("skills: on_load hook %s/%s with scope=%s requires a session id"):format(
              hook.skill_id,
              hook.event_name,
              hook.scope
            ),
          }
          goto continue
        end
        owner = session_id
      end
      local res = registry.register(hook, { owner_session = owner })
      if res.ok then
        if res.deduped then
          result.deduped = result.deduped + 1
        else
          result.registered = result.registered + 1
        end
      else
        result.errors[#result.errors + 1] = {
          event_name = hook.event_name,
          reason = "register",
          message = res.err and res.err.message or "registration failed",
        }
      end
      ::continue::
    end
  end
  return result
end

--- Restore hook state for a restored session: rebuild once/tombstone state
--- from history (no second injection) and re-register on_load hooks of every
--- skill referenced by injected messages' provenance.
---@param session_id string restored session id
---@param messages table[] restored message list
---@param opts? table {
---   discover?: table|nil discover instance (default: fresh default-roots scan),
---   registry?: table|nil registry instance (default: M.registry())
--- }
---@return table result { restored_once=integer, restored_hooks=integer,
---   errors=table[] }
function M.restore_hooks_from_messages(session_id, messages, opts)
  opts = opts or {}
  local injector = require("maxa.runtime.skills.injector")
  local registry = opts.registry or M.registry()

  local result = { restored_once = 0, restored_hooks = 0, errors = {} }

  local injector_instance = opts.injector
  if not injector_instance then
    injector_instance = injector.new({ bus = registry.bus })
  end
  result.restored_once = injector_instance.restore_once_state(session_id, messages)

  -- Collect skill ids referenced by injected hook messages (provenance).
  local skill_ids = {}
  if type(messages) == "table" then
    for _, msg in ipairs(messages) do
      local prov = msg and msg._meta and msg._meta.provenance
      if type(prov) == "table" and type(prov.skill_id) == "string" and prov.skill_id ~= "" then
        skill_ids[prov.skill_id] = true
      end
    end
  end

  local discover = opts.discover
  if not discover then
    local discover_mod = require("maxa.runtime.skills.discover")
    discover = discover_mod.new()
    discover.scan()
  end

  for skill_id in pairs(skill_ids) do
    local record, err = discover.resolve(skill_id)
    if not record then
      result.errors[#result.errors + 1] = {
        event_name = "",
        reason = "resolve",
        message = err and err.message or ("skills: cannot resolve %q while restoring hooks"):format(skill_id),
      }
    else
      local reg = M.register_skill_hooks(record, session_id, { registry = registry })
      result.restored_hooks = result.restored_hooks + reg.registered
      for _, e in ipairs(reg.errors) do
        result.errors[#result.errors + 1] = e
      end
    end
  end

  return result
end

return M
