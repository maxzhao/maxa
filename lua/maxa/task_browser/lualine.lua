-- filepath: lua/maxa/task_browser/lualine.lua
-- Lightweight lualine component for TaskAdmin browser status.

local scanner = require("maxa.task_browser.scanner")
local state = require("maxa.task_browser.state")

local M = {}

local cache = {
  key = nil,
  value = "",
  ok = false,
  at = 0,
}

local function exists(path)
  return type(path) == "string" and path ~= "" and vim.uv.fs_stat(path) ~= nil
end

local function safe_tasks_root(opts)
  local ok, root = pcall(state.tasks_root, opts)
  if not ok then
    return nil
  end
  return root
end

---@param opts table|nil
---@return boolean
function M.cond(opts)
  local root = safe_tasks_root(opts)
  return exists(root)
end

---@param opts table|nil
---@return string
function M.status(opts)
  opts = opts or {}
  local root = safe_tasks_root(opts)
  if not exists(root) then
    return ""
  end

  local tag = state.get_active_tag(opts)
  local ttl = opts.ttl or 5
  local now = vim.uv.now()
  local key = tostring(root) .. "::" .. tostring(tag)
  if cache.key == key and now - cache.at < ttl * 1000 then
    return cache.value
  end

  local ok, progress = pcall(scanner.task_progress, tag, opts)
  if not ok or type(progress) ~= "table" then
    cache = { key = key, value = tag, ok = false, at = now }
    return cache.value
  end

  local value = string.format("%s %d/%d", tag, progress.active or 0, progress.closed or 0)
  cache = { key = key, value = value, ok = true, at = now }
  return value
end

function M.refresh()
  cache = { key = nil, value = "", ok = false, at = 0 }
  scanner.clear_cache()
end

return M
