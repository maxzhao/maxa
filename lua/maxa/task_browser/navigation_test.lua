-- Run: nvim --headless -u NONE --cmd 'set rtp^=.' -l lua/maxa/task_browser/navigation_test.lua

vim.opt.runtimepath:prepend(vim.fn.getcwd())

local state = require("maxa.task_browser.state")
local navigation = require("maxa.task_browser.navigation")

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
    error(string.format("%s: expected %s, got %s", message or "assertion", tostring(expected), tostring(actual)))
  end
end
local function write(path, lines)
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  vim.fn.writefile(lines, path)
end

local root = vim.fn.tempname()
local tag = root .. "/.maxa/tasks/master"
write(root .. "/.maxa/tasks/state.yaml", { "currentTag: master" })
write(tag .. "/_meta.yaml", { "description: fixture" })
for _, id in ipairs({ 1, 2, 3, 1000 }) do
  local base = string.format("%s/task_%03d", tag, id)
  write(base .. "/_meta.yaml", {
    string.format('name: "Task %d"', id),
    "status: pending",
    "priority: medium",
    "dependencies: []",
  })
  write(base .. "/plan.md", { "# Plan" })
  write(base .. "/todo.md", { "# TODO" })
end
local opts = { project_root = root, force = true }
local function ctx(path)
  return state.context_from_path(path, opts)
end

test("next and previous resolve peer plans", function()
  local current = ctx(tag .. "/task_002/plan.md")
  local next_task, next_reason = navigation.find_peer(1, vim.tbl_extend("force", opts, { context = current }))
  eq(nil, next_reason)
  eq("3", next_task.id)
  eq(tag .. "/task_003/plan.md", next_task.plan_file)
  local previous, previous_reason = navigation.find_peer(-1, vim.tbl_extend("force", opts, { context = current }))
  eq(nil, previous_reason)
  eq("1", previous.id)
end)

test("peer boundaries return clear reasons", function()
  local first = ctx(tag .. "/task_001/plan.md")
  local target, reason = navigation.find_peer(-1, vim.tbl_extend("force", opts, { context = first }))
  eq(nil, target)
  eq("已经是当前 tag 的第一个任务", reason)
  local near_large = ctx(tag .. "/task_003/todo.md")
  target, reason = navigation.find_peer(1, vim.tbl_extend("force", opts, { context = near_large }))
  eq(nil, reason)
  eq("1000", target.id)
  local last = ctx(tag .. "/task_1000/todo.md")
  target, reason = navigation.find_peer(1, vim.tbl_extend("force", opts, { context = last }))
  eq(nil, target)
  eq("已经是当前 tag 的最后一个任务", reason)
end)

test("counterpart toggles plan and TODO", function()
  local plan = ctx(tag .. "/task_002/plan.md")
  local path, reason = navigation.counterpart_path(plan, opts)
  eq(nil, reason)
  eq(tag .. "/task_002/todo.md", path)
  local todo = ctx(tag .. "/task_002/todo.md")
  path, reason = navigation.counterpart_path(todo, opts)
  eq(nil, reason)
  eq(tag .. "/task_002/plan.md", path)
end)

test("outside and supporting documents are not TaskAdmin navigation contexts", function()
  write(tag .. "/task_002/notes.md", { "# Notes" })
  eq(nil, ctx(tag .. "/task_002/notes.md"))
  local peers, index, reason = navigation.get_peer_tasks(nil, opts)
  eq(0, #peers)
  eq(nil, index)
  eq("当前 buffer 不属于 TaskAdmin plan/TODO", reason)
end)

vim.fn.delete(root, "rf")
print(string.format("\n%d passed, %d failed", passed, failed))
if failed > 0 then
  vim.cmd("cquit 1")
end
