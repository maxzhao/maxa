-- filepath: lua/maxa/task_browser/scanner.lua
-- Read-only scanner for single-level TaskAdmin task workspaces.

local metadata = require("maxa.task_browser.frontmatter")
local state = require("maxa.task_browser.state")

local M = {}
local cache = {}

local function joinpath(...)
  return (table.concat({ ... }, "/"):gsub("/+", "/"))
end

local function normalize(path)
  if type(path) ~= "string" or path == "" then
    return ""
  end
  return (vim.fn.fnamemodify(path, ":p"):gsub("\\", "/"):gsub("/+$", ""))
end

local function exists(path)
  return type(path) == "string" and vim.uv.fs_stat(path) ~= nil
end

local function mtime(path)
  local stat = vim.uv.fs_stat(path)
  return stat and stat.mtime.sec or 0
end

local function empty_stats()
  local counts = { total = 0, unknown = 0 }
  for _, status in ipairs(state.STATUS_VALUES) do
    counts[status] = 0
  end
  return counts
end

local function bump(stats, status)
  stats.total = stats.total + 1
  if stats[status] ~= nil then
    stats[status] = stats[status] + 1
  else
    stats.unknown = stats.unknown + 1
  end
end

local function task_from_dir(tag, id_num, task_dir, opts)
  local paths = state.paths_for_id(tag, tostring(id_num), opts)
  if not paths or not exists(paths.meta_file) or not exists(paths.plan_file) or not exists(paths.todo_file) then
    return nil
  end
  local meta, err = metadata.parse_file(paths.meta_file)
  if err then
    return nil
  end
  return {
    id = tostring(id_num),
    tag = tag,
    task_dir = task_dir,
    meta_file = paths.meta_file,
    plan_file = paths.plan_file,
    todo_file = paths.todo_file,
    name = meta.name or "",
    description = meta.description or "",
    status = meta.status or "unknown",
    priority = meta.priority or "medium",
    dependencies = type(meta.dependencies) == "table" and meta.dependencies or {},
    workspace = meta.workspace,
    created = meta.created,
    updated = meta.updated,
    metadata = meta,
  }
end

local function scan_uncached(tag, opts)
  opts = opts or {}
  tag = tag or state.get_active_tag(opts)
  if not state.valid_tag(tag) then
    return {
      tag = tag,
      tag_root = nil,
      tasks = {},
      by_id = {},
      stats = empty_stats(),
      active = 0,
      closed = 0,
      exists = false,
      mtime = 0,
      error = "invalid tag",
    }
  end
  local tag_root = joinpath(state.tasks_root(opts), tag)
  local tasks, by_id = {}, {}
  local stats = empty_stats()
  local active, closed = 0, 0
  if vim.fn.isdirectory(tag_root) ~= 1 then
    return {
      tag = tag,
      tag_root = tag_root,
      tasks = tasks,
      by_id = by_id,
      stats = stats,
      active = active,
      closed = closed,
      exists = false,
      mtime = 0,
    }
  end

  local ok, entries = pcall(vim.fn.readdir, tag_root)
  if not ok or type(entries) ~= "table" then
    entries = {}
  end
  local task_dirs = {}
  for _, entry in ipairs(entries) do
    local id_num = entry:match("^task_(%d+)$")
    local full = joinpath(tag_root, entry)
    if id_num and entry == string.format("task_%03d", tonumber(id_num)) and vim.fn.isdirectory(full) == 1 then
      table.insert(task_dirs, { id = tonumber(id_num), path = full })
    end
  end
  table.sort(task_dirs, function(a, b)
    return a.id < b.id
  end)

  for _, entry in ipairs(task_dirs) do
    local task = task_from_dir(tag, entry.id, entry.path, opts)
    if task then
      table.insert(tasks, task)
      by_id[task.id] = task
      bump(stats, task.status)
      if task.status == "pending" or task.status == "in-progress" or task.status == "review" then
        active = active + 1
      elseif task.status == "done" or task.status == "deferred" or task.status == "cancelled" then
        closed = closed + 1
      end
    end
  end

  return {
    tag = tag,
    tag_root = tag_root,
    tasks = tasks,
    by_id = by_id,
    stats = stats,
    active = active,
    closed = closed,
    exists = true,
    scanned_at = os.time(),
    mtime = mtime(tag_root),
  }
end

local function cache_key(tag, opts)
  return normalize(state.project_root(opts)) .. "::" .. tostring(tag)
end

function M.scan(tag, opts)
  opts = opts or {}
  tag = tag or state.get_active_tag(opts)
  if not state.valid_tag(tag) then
    return scan_uncached(tag, opts)
  end
  local key = cache_key(tag, opts)
  local ttl = opts.ttl or 2
  local now = vim.uv.now()
  local tag_root = joinpath(state.tasks_root(opts), tag)
  local current_mtime = mtime(tag_root)
  local cached = cache[key]
  if not opts.force and cached and cached.mtime == current_mtime and now - cached.now < ttl * 1000 then
    return cached.result
  end
  local result = scan_uncached(tag, opts)
  cache[key] = { result = result, mtime = current_mtime, now = now }
  return result
end

function M.clear_cache()
  cache = {}
end

function M.list_tasks(tag, opts)
  return M.scan(tag, opts).tasks
end

function M.stats(tag, opts)
  return M.scan(tag, opts).stats
end

function M.task_progress(tag, opts)
  local result = M.scan(tag, opts)
  return { active = result.active or 0, closed = result.closed or 0, total = result.stats.total or 0 }
end

function M.get_task(id, tag, opts)
  return M.scan(tag, opts).by_id[tostring(id)]
end

return M
