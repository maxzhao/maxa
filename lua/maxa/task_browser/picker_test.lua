-- Run: nvim --headless -u NONE --cmd 'set rtp^=.' -l lua/maxa/task_browser/picker_test.lua

vim.opt.runtimepath:prepend(vim.fn.getcwd())

local picker = require("maxa.task_browser.picker")

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
write(root .. "/.maxa/tasks/state.yaml", { "currentTag: master" })
for _, tag in ipairs({ "master", "other" }) do
  write(root .. "/.maxa/tasks/" .. tag .. "/_meta.yaml", { "description: fixture" })
end
local function task(tag, id, status, priority, name)
  local base = string.format("%s/.maxa/tasks/%s/task_%03d", root, tag, id)
  write(base .. "/_meta.yaml", {
    'name: "' .. name .. '"',
    "status: " .. status,
    "priority: " .. priority,
    "dependencies: []",
  })
  write(base .. "/plan.md", { "# Plan" })
  write(base .. "/todo.md", { "# TODO" })
end
task("master", 1, "pending", "high", "First")
task("master", 2, "done", "medium", "Second")
task("master", 1000, "review", "low", "Large ID")
task("other", 1, "review", "low", "Other")
local opts = { project_root = root, force = true }

test("picker items contain peer plan and TODO paths", function()
  local items = picker.items(opts)
  eq(3, #items)
  eq("1", items[1].id)
  truthy(items[1].plan_file:match("task_001/plan%.md$"))
  truthy(items[1].todo_file:match("task_001/todo%.md$"))
  eq(nil, items[1].parent_id)
  eq(nil, items[1].progress_file)
  local large = vim.iter(items):find(function(item)
    return item.id == "1000"
  end)
  truthy(large and large.plan_file:match("task_1000/plan%.md$"))
end)

test("all-tag and status filters use one picker model", function()
  local items = picker.items(vim.tbl_extend("force", opts, { all_tags = true, tag = "*" }))
  eq(4, #items)
  items = picker.items(vim.tbl_extend("force", opts, { status = "done" }))
  eq(1, #items)
  eq("2", items[1].id)
end)

test("next-task output converts to a peer picker item", function()
  local item = picker.item_from_next_task({
    id = 2,
    name = "Second",
    status = "pending",
    priority = "medium",
    plan_file = root .. "/.maxa/tasks/master/task_002/plan.md",
    todo_file = root .. "/.maxa/tasks/master/task_002/todo.md",
  }, "master", opts)
  eq("2", item.id)
  eq(nil, item.parent_id)
  truthy(item.todo_file:match("task_002/todo%.md$"))
end)

test("picker actions expose TODO rather than progress", function()
  local config = picker.picker_opts(opts)
  truthy(config.actions.task_browser_open_todo)
  eq(nil, config.actions.task_browser_open_progress)
  eq("task_browser_open_todo", config.win.list.keys.p[1])
end)

vim.fn.delete(root, "rf")
print(string.format("\n%d passed, %d failed", passed, failed))
if failed > 0 then
  vim.cmd("cquit 1")
end
