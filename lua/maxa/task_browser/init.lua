-- filepath: lua/maxa/task_browser/init.lua
-- Public API for the Neovim TaskAdmin browser.

local M = {}

M.frontmatter = require("maxa.task_browser.frontmatter")
M.scanner = require("maxa.task_browser.scanner")
M.state = require("maxa.task_browser.state")
M.navigation = require("maxa.task_browser.navigation")
M.picker = require("maxa.task_browser.picker")

function M.list(opts)
  return M.picker.open(opts)
end

function M.open_picker(opts)
  return M.picker.open(opts)
end

function M.picker_items(opts)
  return M.picker.items(opts)
end

function M.next_executable_items(opts)
  return M.picker.next_task_items(opts)
end

function M.open_next_executable(opts)
  return M.picker.open_next_tasks(opts)
end

function M.next_task(opts)
  return M.navigation.next_task(opts)
end

function M.previous_task(opts)
  return M.navigation.previous_task(opts)
end

function M.toggle_todo(opts)
  return M.navigation.toggle_todo(opts)
end

function M.clear_cache()
  return M.scanner.clear_cache()
end

return M
