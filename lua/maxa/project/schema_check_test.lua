-- filepath: lua/maxa/project/schema_check_test.lua
-- Run: nvim --headless -l lua/maxa/project/schema_check_test.lua
local passed = 0
local failed = 0
local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then
    passed = passed + 1
    print("✓ " .. name)
  else
    failed = failed + 1
    print("✗ " .. name)
    print("  Error: " .. tostring(err))
  end
end
local function assert_equal(expected, actual, msg)
  if expected ~= actual then
    error(string.format("%s: expected %s, got %s", msg or "assertion failed", tostring(expected), tostring(actual)))
  end
end
package.loaded["maxa.project.schema_check"] = nil
local schema_check = require("maxa.project.schema_check")
local root = vim.fn.getcwd(-1, -1)
local tmp = root .. "/.maxa/tmp/schema-check-test"
vim.fn.delete(tmp, "rf")
vim.fn.mkdir(tmp .. "/project/.maxa", "p")
local function write(path, body)
  local fd = assert(io.open(path, "w"))
  fd:write(body)
  fd:close()
end
local runtime_file = root .. "/.version"
local runtime_backup
local fd = io.open(runtime_file, "r")
if fd then
  runtime_backup = fd:read("*a")
  fd:close()
end
local function with_runtime_version(version, fn)
  write(runtime_file, tostring(version) .. "\n")
  local ok, err = pcall(fn)
  if runtime_backup ~= nil then
    write(runtime_file, runtime_backup)
  else
    vim.fn.delete(runtime_file)
  end
  if not ok then
    error(err)
  end
end
local project = tmp .. "/project"

test("missing project meta is version 0 and requires upgrade when runtime is 1", function()
  vim.fn.delete(project .. "/.maxa/_meta.yaml")
  with_runtime_version(1, function()
    local result = schema_check.check_project(project)
    assert_equal("project-upgrade-required", result.status)
    assert_equal(0, result.project_version)
    assert_equal(1, result.runtime_version)
  end)
end)

test("equal project/runtime versions are ok", function()
  write(project .. "/.maxa/_meta.yaml", "schema_version: 1\n")
  with_runtime_version(1, function()
    local result = schema_check.check_project(project)
    assert_equal("ok", result.status)
    assert_equal(1, result.project_version)
    assert_equal(1, result.runtime_version)
  end)
end)

test("newer project requires runtime upgrade", function()
  write(project .. "/.maxa/_meta.yaml", "schema_version: 2\n")
  with_runtime_version(1, function()
    local result = schema_check.check_project(project)
    assert_equal("runtime-upgrade-required", result.status)
    assert_equal(2, result.project_version)
    assert_equal(1, result.runtime_version)
  end)
end)

test("old version key is ignored and cannot override the canonical key", function()
  with_runtime_version(1, function()
    write(project .. "/.maxa/_meta.yaml", "maxa_schema_version: 1\n")
    local legacy = schema_check.check_project(project)
    assert_equal(0, legacy.project_version)
    assert_equal("project-upgrade-required", legacy.status)
    write(project .. "/.maxa/_meta.yaml", "maxa_schema_version: 2\nschema_version: 1\n")
    assert_equal("ok", schema_check.check_project(project).status)
  end)
end)

test("invalid canonical version retains the invalid-version outcome", function()
  write(project .. "/.maxa/_meta.yaml", "schema_version: -1\n")
  with_runtime_version(1, function()
    assert_equal("project-version-invalid", schema_check.check_project(project).status)
  end)
end)

test("non-ok result uses Snacks-style confirm popup when available", function()
  local captured
  local shown = schema_check._show_result_confirm_for_test({
    status = "project-upgrade-required",
    project_version = 0,
    runtime_version = 1,
    project_root = project,
  }, {
    win_factory = function(opts)
      captured = opts
      return { close = function() end }
    end,
  })
  assert_equal(true, shown)
  assert_equal("function", type(captured.keys.Y[2]), "Y confirm key should exist")
  assert_equal(nil, captured.keys.n, "n cancel key should not be registered")
  assert_equal("function", type(captured.keys.q[2]), "q cancel key should exist")
  assert_equal(" Maxa Schema Check ", captured.title)
end)
vim.fn.delete(tmp, "rf")
vim.fn.delete(tmp, "rf")
print(string.format("\n%d passed, %d failed", passed, failed))
if failed > 0 then
  os.exit(1)
end
