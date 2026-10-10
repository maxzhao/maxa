-- Run: nvim --headless -u NONE -l lua/maxa/session/default_adapter_test.lua

local root = vim.fn.getcwd()
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local total, failed = 0, 0
local function test(name, fn)
  total = total + 1
  local ok, err = pcall(fn)
  if ok then
    print("PASS " .. name)
  else
    failed = failed + 1
    print("FAIL " .. name .. ": " .. tostring(err))
  end
end
local function eq(actual, expected)
  assert(vim.deep_equal(actual, expected), "expected " .. vim.inspect(expected) .. ", got " .. vim.inspect(actual))
end
local function write(path, lines)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  vim.fn.writefile(lines, path)
end

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
local original_stdpath = vim.fn.stdpath
vim.fn.stdpath = function(kind)
  if kind == "config" then
    return tmp .. "/config"
  end
  return original_stdpath(kind)
end
vim.fn.mkdir(tmp .. "/config", "p")

package.loaded["maxa.session.default_adapter"] = nil
local state = require("maxa.session.default_adapter")
local fallback = { adapter = "shared", model = "shared-model" }
local project = tmp .. "/project"
local meta = project .. "/.maxa/_meta.yaml"
local created = "created: 2026-04-21T13:29:01+00:00"
write(meta, { "name: fixture", "schema_version: 1", created })

test("shared fallback", function()
  local value = assert(state.resolve_effective(project, fallback))
  eq({ value.adapter, value.model, value.scope, value.inherited }, { "shared", "shared-model", "shared", true })
end)

test("global override and project inheritance", function()
  assert(state.write_global_override("global", "global-model"))
  local value = assert(state.resolve_effective(project, fallback))
  eq({ value.adapter, value.model, value.scope, value.inherited }, { "global", "global-model", "global", true })
end)

test("project override wins and preserves yaml", function()
  assert(state.write_project_override(project, "project-adapter", "project-model"))
  local value = assert(state.resolve_effective(project, fallback))
  eq({ value.adapter, value.model, value.scope }, { "project-adapter", "project-model", "project" })
  local text = table.concat(vim.fn.readfile(meta), "\n")
  assert(text:find(created, 1, true))
  assert(text:find('default_adapter: "project-adapter"', 1, true))
  assert(text:find('default_model: "project-model"', 1, true))
  assert(not text:find("maxa_ai:", 1, true))
end)

test("project clear restores global and preserves yaml", function()
  assert(state.clear_project_override(project))
  local value = assert(state.resolve_effective(project, fallback))
  eq({ value.adapter, value.model, value.scope }, { "global", "global-model", "global" })
  local text = table.concat(vim.fn.readfile(meta), "\n")
  assert(not text:find("maxa_ai:"))
  assert(text:find(created, 1, true))
end)

test("global clear restores shared and preserves env", function()
  write(state.env_path(), { "OTHER=value", "MAXA_AI_DEFAULT_ADAPTER=global", "MAXA_AI_DEFAULT_MODEL=global-model" })
  assert(state.clear_global_override())
  eq(vim.fn.readfile(state.env_path()), { "OTHER=value" })
  local value = assert(state.resolve_effective(project, fallback))
  eq({ value.adapter, value.model }, { "shared", "shared-model" })
end)

test("project Soul supports literal text and survives adapter updates", function()
  write(meta, {
    "name: fixture",
    "soul: |",
    "  # Specialist Soul",
    "  default_model: Preserve this Soul text.",
  })
  eq(assert(state.read_project_soul(project)), "# Specialist Soul\ndefault_model: Preserve this Soul text.\n")
  assert(state.write_project_override(project, "project-adapter", "project-model"))
  assert(state.clear_project_override(project))
  eq(assert(state.read_project_soul(project)), "# Specialist Soul\ndefault_model: Preserve this Soul text.\n")
end)

test("missing project metadata fails without creation", function()
  local missing = tmp .. "/missing"
  local ok = state.write_project_override(missing, "a", "m")
  assert(ok == false)
  assert(vim.fn.filereadable(missing .. "/.maxa/_meta.yaml") == 0)
end)

test("partial project override fails closed", function()
  write(meta, { "name: fixture", "default_adapter: only" })
  local value, err = state.read_project_override(project)
  assert(value == nil and tostring(err):find("incomplete"))
  local before = table.concat(vim.fn.readfile(meta), "\n")
  local ok = state.write_project_override(project, "a", "m")
  assert(ok == false)
  eq(table.concat(vim.fn.readfile(meta), "\n"), before)
end)

-- Existing projects read without mutation; explicit writes migrate the old block.
test("legacy wrapper migrates conservatively on explicit edit", function()
  write(meta, {
    "name: fixture",
    "maxa_ai: # runtime settings",
    "  # retain this comment",
    "  soul: |",
    "    # Legacy Soul",
    "    exact text",
    "  default_adapter: legacy",
    "  default_model: legacy-model",
    "  abilities:",
    "    states:",
    "      browser: false",
    "notes:",
    "- keep",
  })
  local before = table.concat(vim.fn.readfile(meta), "\n")
  eq(assert(state.read_project_override(project)).adapter, "legacy")
  eq(table.concat(vim.fn.readfile(meta), "\n"), before)
  assert(state.write_project_override(project, "project-adapter", "project-model"))
  local text = table.concat(vim.fn.readfile(meta), "\n")
  assert(not text:find("maxa_ai:", 1, true))
  assert(text:find("# retain this comment", 1, true))
  assert(text:find("# runtime settings", 1, true))
  assert(text:find("notes:\n- keep", 1, true))
  eq(assert(state.read_project_soul(project)), "# Legacy Soul\nexact text\n")
  assert(not require("maxa.project.settings").ability_enabled(project, "browser"))
end)

test("root and legacy collisions fail without overwrite", function()
  write(meta, { "name: fixture", "default_adapter: root", "default_model: root-model", "maxa_ai:", "  default_adapter: legacy", "  default_model: legacy-model" })
  local before = table.concat(vim.fn.readfile(meta), "\n")
  local value, err = state.read_project_override(project)
  assert(not value and tostring(err):find("conflict", 1, true))
  assert(not state.write_project_override(project, "a", "m"))
  eq(table.concat(vim.fn.readfile(meta), "\n"), before)
end)

vim.fn.stdpath = original_stdpath
vim.fn.delete(tmp, "rf")
print(string.format("RESULT %d passed, %d failed", total - failed, failed))
if failed > 0 then
  vim.cmd("cquit 1")
end
