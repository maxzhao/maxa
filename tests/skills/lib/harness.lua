-- filepath: tests/skills/lib/harness.lua
--- Phase-3 W5 skills-suite harness: hermetic three-root skill tree.
---
--- Creates three temporary discovery roots (bundled / config / project) so
--- fixtures never depend on the real runtimepath or the repo's own `skills/`.
--- The harness writes SKILL.md fixtures (rendered frontmatter + body), builds
--- discover/loader instances bound to the temp roots, and cleans up.

local discover = require("maxa.runtime.skills.discover")
local loader = require("maxa.runtime.skills.loader")

local M = {}

--- Escape a string for double-quoted YAML scalar rendering.
---@param s string
---@return string
local function yaml_quote(s)
  return '"' .. s:gsub('"', '\\"') .. '"'
end

--- Render a scalar YAML token: booleans/numbers unquoted, strings quoted.
---@param v any
---@return string
local function render_scalar(v)
  if type(v) == "boolean" or type(v) == "number" then
    return tostring(v)
  end
  return yaml_quote(tostring(v))
end

--- Render one YAML value at an indentation level (fixture-level YAML subset:
--- scalars, lists, nested mappings — enough for hook filter frontmatter).
---@param v any
---@param indent integer spaces
---@return string[] lines
local function render_value(v, indent)
  local pad = string.rep(" ", indent)
  if type(v) == "table" then
    -- Empty table renders as [] (existing behavior).
    if next(v) == nil then
      return { pad .. "[]" }
    end
    -- Sequence (array) rendering.
    local is_seq = true
    for k in pairs(v) do
      if type(k) ~= "number" then
        is_seq = false
        break
      end
    end
    if is_seq then
      local lines = {}
      for _, item in ipairs(v) do
        if type(item) == "table" then
          lines[#lines + 1] = pad .. "-"
          local sub = render_value(item, indent + 4)
          for _, l in ipairs(sub) do
            lines[#lines + 1] = l
          end
        else
          lines[#lines + 1] = pad .. "- " .. render_scalar(item)
        end
      end
      return lines
    end
    -- Mapping rendering.
    local lines = {}
    for k, item in pairs(v) do
      if type(item) == "table" then
        lines[#lines + 1] = pad .. tostring(k) .. ":"
        local sub = render_value(item, indent + 2)
        for _, l in ipairs(sub) do
          lines[#lines + 1] = l
        end
      else
        lines[#lines + 1] = pad .. tostring(k) .. ": " .. render_scalar(item)
      end
    end
    return lines
  end
  return { pad .. render_scalar(v) }
end

--- Render a frontmatter mapping from Lua fields (fixture-level YAML subset).
---@param fields table string|string[]|table values (maps supported for hooks)
---@return string
function M.render_frontmatter(fields)
  local lines = { "---" }
  for k, v in pairs(fields) do
    if type(v) == "table" then
      if next(v) == nil then
        lines[#lines + 1] = k .. ": []"
      else
        -- render_value distinguishes sequences from mappings; string-keyed
        -- maps (opts/filter) MUST NOT be treated as empty arrays.
        lines[#lines + 1] = k .. ":"
        local sub = render_value(v, 2)
        for _, l in ipairs(sub) do
          lines[#lines + 1] = l
        end
      end
    else
      lines[#lines + 1] = k .. ": " .. render_scalar(v)
    end
  end
  lines[#lines + 1] = "---"
  return table.concat(lines, "\n")
end

--- Create a hermetic hook environment: isolated events bus + registry + fire
--- dispatcher + conversation stack (W6 fixture base).
---@return table env { bus, registry, fire, stack, injector }
function M.hook_env()
  local events = require("maxa.runtime.events")
  local registry_mod = require("maxa.runtime.skills.registry")
  local fire_mod = require("maxa.runtime.skills.fire")
  local injector_mod = require("maxa.runtime.skills.injector")
  local conversation = require("maxa.runtime.conversation")
  local bus = events.new()
  local registry = registry_mod.new({ bus = bus })
  local injector = injector_mod.new({ bus = bus })
  local fire = fire_mod.new({ registry = registry, bus = bus, injector = injector })
  local stack = conversation.new_stack()
  return {
    bus = bus,
    registry = registry,
    fire = fire,
    injector = injector,
    stack = stack,
  }
end

--- Create a fresh harness with three temp roots.
---@return table h
function M.new()
  local h = {}

  local function mktemp(tag)
    local root = vim.fn.tempname() .. "-skills-" .. tag
    vim.fn.mkdir(root, "p")
    return root
  end

  h.bundled_root = mktemp("bundled")
  h.config_root = mktemp("config")
  h.project_root = mktemp("project")

  -- Instance passthrough for the module-level hermetic hook environment.
  h.hook_env = M.hook_env

  --- Discovery roots in priority order (project > config > bundled).
  ---@return table[] { path=string, kind=string }
  function h.roots()
    return {
      { path = h.project_root, kind = "project" },
      { path = h.config_root, kind = "config" },
      { path = h.bundled_root, kind = "bundled" },
    }
  end

  --- Write a skill fixture: `<root>/<id>/SKILL.md` with rendered frontmatter.
  ---@param root string discovery root path
  ---@param id string relative skill id (`name` or `main/sub`, `/`-separated)
  ---@param fields table frontmatter fields
  ---@param body string markdown body
  function h.write_skill(root, id, fields, body)
    local dir = root
    for part in id:gmatch("[^/]+") do
      dir = dir .. "/" .. part
    end
    vim.fn.mkdir(dir, "p")
    local fh = assert(io.open(dir .. "/SKILL.md", "wb"))
    fh:write(M.render_frontmatter(fields) .. "\n" .. body .. "\n")
    fh:close()
  end

  --- Write a raw file under a root (invalid-metadata fixtures).
  ---@param root string discovery root path
  ---@param rel string relative path under root (e.g. `bad/SKILL.md`)
  ---@param content string
  function h.write_skill_raw(root, rel, content)
    local full = root .. "/" .. rel
    local parent = full:match("^(.*)/[^/]+$")
    if parent then
      vim.fn.mkdir(parent, "p")
    end
    local fh = assert(io.open(full, "wb"))
    fh:write(content)
    fh:close()
  end

  --- Skill directory for an id under a root (mirrors write_skill nesting).
  ---@param root string discovery root path
  ---@param id string relative skill id
  ---@return string dir
  function h.skill_dir(root, id)
    local dir = root
    for part in id:gmatch("[^/]+") do
      dir = dir .. "/" .. part
    end
    return dir
  end

  --- Write a markdown SkillHook file: `<root>/<id>/hooks/<EventName>.md`.
  ---@param root string discovery root path
  ---@param id string relative skill id
  ---@param event_name string hook event name (no extension)
  ---@param fields table hook frontmatter fields
  ---@param body string hook body (## user / ## llm / ## system sections)
  function h.write_hook_md(root, id, event_name, fields, body)
    local hooks_dir = h.skill_dir(root, id) .. "/hooks"
    vim.fn.mkdir(hooks_dir, "p")
    local fh = assert(io.open(hooks_dir .. "/" .. event_name .. ".md", "wb"))
    fh:write(M.render_frontmatter(fields) .. "\n" .. body .. "\n")
    fh:close()
  end

  --- Write a lua SkillHook file: `<root>/<id>/hooks/<EventName>.lua`.
  ---@param root string discovery root path
  ---@param id string relative skill id
  ---@param event_name string hook event name (no extension)
  ---@param content string lua chunk source (must return a table)
  function h.write_hook_lua(root, id, event_name, content)
    local hooks_dir = h.skill_dir(root, id) .. "/hooks"
    vim.fn.mkdir(hooks_dir, "p")
    local fh = assert(io.open(hooks_dir .. "/" .. event_name .. ".lua", "wb"))
    fh:write(content)
    fh:close()
  end

  --- Discover instance bound to the harness roots.
  ---@return table d
  function h.discover()
    return discover.new({ roots = h.roots() })
  end

  --- Loader instance bound to a harness discover instance.
  ---@param d table discover instance
  ---@return table l
  function h.loader(d)
    return loader.new({ discover = d })
  end

  --- Remove all temp roots (best effort).
  function h.cleanup()
    for _, root in ipairs({ h.project_root, h.config_root, h.bundled_root }) do
      pcall(vim.fn.delete, root, "rf")
    end
  end

  return h
end

return M
