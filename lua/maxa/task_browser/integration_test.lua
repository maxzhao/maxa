-- Run: nvim --headless -u NONE --cmd 'set rtp^=.' -l lua/maxa/task_browser/integration_test.lua

local repo_root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(repo_root)

local lualine = require("maxa.task_browser.lualine")
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
local function truthy(value, message)
  if not value then
    error(message or "expected truthy value")
  end
end
local function write(path, lines)
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  vim.fn.writefile(lines, path)
end
local function map_exists(lhs, bufnr)
  for _, map in ipairs(vim.api.nvim_buf_get_keymap(bufnr, "n")) do
    if map.lhs == lhs then
      return map
    end
  end
end

local root = vim.fn.tempname()
local tag = root .. "/.maxa/tasks/master"
write(root .. "/.maxa/tasks/state.yaml", { "currentTag: master" })
write(tag .. "/_meta.yaml", { "description: fixture" })
for id, status in ipairs({ "pending", "done" }) do
  local base = string.format("%s/task_%03d", tag, id)
  write(base .. "/_meta.yaml", {
    string.format('name: "Task %d"', id),
    "status: " .. status,
    "priority: medium",
    "dependencies: []",
  })
  write(base .. "/plan.md", { "# Plan" })
  write(base .. "/todo.md", { "# TODO" })
end
write(tag .. "/task_1000/_meta.yaml", {
  'name: "Large ID"',
  "status: done",
  "priority: low",
  "dependencies: []",
})
write(tag .. "/task_1000/plan.md", { "# Plan" })
write(tag .. "/task_1000/todo.md", { "# TODO" })
local opts = { project_root = root, force = true, ttl = 0 }

test("lualine reports active and closed peer-task counts", function()
  eq(true, lualine.cond(opts))
  eq("master 1/2", lualine.status(opts))
end)

test("lualine hides outside TaskAdmin projects", function()
  local missing = { project_root = root .. "/missing" }
  eq(false, lualine.cond(missing))
  eq("", lualine.status(missing))
end)

test("plugin registers the single-level command and buffer surface", function()
  vim.fn.chdir(root)
  local spec = dofile(repo_root .. "/lua/plugins/task_browser.lua")
  local snacks
  for _, plugin in ipairs(spec) do
    if plugin[1] == "folke/snacks.nvim" then
      snacks = plugin
    end
  end
  truthy(snacks)
  snacks.init()

  for _, command in ipairs({
    "TaskBrowserList",
    "TaskBrowserNextExecutable",
    "TaskBrowserNextTask",
    "TaskBrowserPreviousTask",
    "TaskBrowserToggleTodo",
    "TaskBrowserSwitchTag",
    "TaskBrowserRefresh",
  }) do
    eq(2, vim.fn.exists(":" .. command), command .. " should exist")
  end
  for _, retired in ipairs({
    "TaskBrowserNextSubtask",
    "TaskBrowserPrevSubtask",
    "TaskBrowserToggleProgress",
    "TaskBrowserParentTask",
    "TaskBrowserFirstSubtask",
  }) do
    eq(0, vim.fn.exists(":" .. retired), retired .. " should be absent")
  end

  vim.cmd.edit(vim.fn.fnameescape(tag .. "/task_1000/plan.md"))
  local task_buf = vim.api.nvim_get_current_buf()
  truthy(map_exists("]n", task_buf), "task plan should have next-task key")
  truthy(map_exists("[n", task_buf), "task plan should have previous-task key")
  truthy(map_exists("]g", task_buf), "task plan should have plan/TODO key")
  eq(nil, map_exists("[u", task_buf), "parent key should be absent")
  eq(nil, map_exists("]u", task_buf), "child key should be absent")

  vim.cmd.edit(vim.fn.fnameescape(repo_root .. "/lua/maxa/task_browser/integration_test.lua"))
  local other_buf = vim.api.nvim_get_current_buf()
  eq(nil, map_exists("]n", other_buf), "ordinary buffer should not have task keys")
end)

vim.fn.chdir(repo_root)
vim.fn.delete(root, "rf")
print(string.format("\n%d passed, %d failed", passed, failed))
if failed > 0 then
  vim.cmd("cquit 1")
end
