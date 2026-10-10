-- Run: nvim --headless -u NONE --cmd 'set rtp^=.' -l lua/maxa/task_browser/scanner_test.lua

vim.opt.runtimepath:prepend(vim.fn.getcwd())

local metadata = require("maxa.task_browser.frontmatter")
local state = require("maxa.task_browser.state")
local scanner = require("maxa.task_browser.scanner")

local passed, failed = 0, 0
local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then
    passed = passed + 1
    print("✓ " .. name)
  else
    failed = failed + 1
    print("✗ " .. name .. "\n  " .. tostring(err))
  end
end
local function eq(expected, actual, message)
  if expected ~= actual then
    error(string.format("%s: expected %s, got %s", message or "assertion", vim.inspect(expected), vim.inspect(actual)))
  end
end
local function truthy(value, message)
  if not value then
    error(message or "expected truthy value")
  end
end
local function write(path, lines)
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  vim.fn.writefile(lines, path)
end

local root = vim.fn.tempname()
local tag = root .. "/.maxa/tasks/master"
write(root .. "/.maxa/tasks/state.yaml", { "currentTag: master" })
write(tag .. "/_meta.yaml", { 'description: "fixture"' })
write(tag .. "/task_001/_meta.yaml", {
  'name: "First"',
  "status: pending",
  "priority: high",
  "dependencies: []",
})
write(tag .. "/task_001/plan.md", { "# Plan" })
write(tag .. "/task_001/todo.md", { "# TODO" })
write(tag .. "/task_002/_meta.yaml", {
  'name: "Second"',
  "status: done",
  "priority: medium",
  "dependencies: [1]",
})
write(tag .. "/task_002/plan.md", { "# Plan" })
write(tag .. "/task_002/todo.md", { "# TODO" })
write(tag .. "/task_1000/_meta.yaml", {
  'name: "Large ID"',
  "status: review",
  "priority: low",
  "dependencies: [2]",
})
write(tag .. "/task_1000/plan.md", { "# Plan" })
write(tag .. "/task_1000/todo.md", { "# TODO" })
write(tag .. "/task_003/_meta.yaml", { 'name: "Incomplete"' })
local opts = { project_root = root, force = true, task_admin_root = vim.fn.getcwd() .. "/abilities/task-admin" }

test("metadata parser reads bare YAML", function()
  local parsed, err = metadata.parse_file(tag .. "/task_002/_meta.yaml")
  eq(nil, err)
  eq("Second", parsed.name)
  eq(1, parsed.dependencies[1])
end)

test("state maps integer IDs to task workspaces", function()
  eq("master", state.get_active_tag(opts))
  local paths = state.paths_for_id("master", "2", opts)
  eq(tag .. "/task_002", paths.task_dir)
  eq(tag .. "/task_002/plan.md", paths.plan_file)
  eq(nil, state.paths_for_id("master", "2.1", opts))
  eq(nil, state.paths_for_id("../escape", "2", opts))
  eq(nil, state.switch_tag_cmd("a/b", opts))
  local ctx = state.context_from_path(paths.todo_file, opts)
  eq("2", ctx.id)
  eq("todo", ctx.kind)
  ctx = state.context_from_path(tag .. "/task_1000/plan.md", opts)
  eq("1000", ctx.id)
end)

test("CLI commands use uv project runtime", function()
  local cmd = state.next_task_cmd(opts)
  eq("uv", cmd[1])
  eq("run", cmd[2])
  eq("--project", cmd[3])
  truthy(cmd[4]:match("/abilities/task%-admin$"), cmd[4])
  eq("python", cmd[5])
end)

test("scanner lists complete peer tasks and active/closed counts", function()
  local result = scanner.scan("master", opts)
  eq(3, #result.tasks)
  eq("1", result.tasks[1].id)
  eq("2", result.tasks[2].id)
  eq("1000", result.tasks[3].id)
  eq(2, result.active)
  eq(1, result.closed)
  eq(nil, result.by_id["3"])
  local invalid = scanner.scan("../escape", opts)
  eq(false, invalid.exists)
  eq("invalid tag", invalid.error)
end)

vim.fn.delete(root, "rf")
print(string.format("\n%d passed, %d failed", passed, failed))
if failed > 0 then
  vim.cmd("cquit 1")
end
