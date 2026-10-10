-- filepath: lua/maxa/task_browser/navigation.lua
-- Navigation helpers for peer TaskAdmin tasks and plan/TODO counterparts.

local scanner = require("maxa.task_browser.scanner")
local state = require("maxa.task_browser.state")

local M = {}

local function notify(message, level)
  vim.notify(message, level or vim.log.levels.INFO, { title = "TaskAdmin Browser" })
end

local function exists(path)
  return type(path) == "string" and path ~= "" and vim.uv.fs_stat(path) ~= nil
end

local function edit(path)
  if not exists(path) then
    notify("文件不存在: " .. tostring(path), vim.log.levels.WARN)
    return false
  end
  vim.cmd.edit(vim.fn.fnameescape(path))
  return true
end

function M.unavailable_reason(ctx)
  if not ctx then
    return "当前 buffer 不属于 TaskAdmin plan/TODO"
  end
  if not ctx.id then
    return "无法识别当前 TaskAdmin 任务 ID"
  end
  return nil
end

function M.get_peer_tasks(ctx, opts)
  opts = opts or {}
  ctx = ctx or state.context_from_buf(0, opts)
  local reason = M.unavailable_reason(ctx)
  if reason then
    return {}, nil, reason
  end
  local peers = scanner.list_tasks(ctx.tag, opts)
  table.sort(peers, function(a, b)
    return state.compare_ids(a.id, b.id)
  end)
  for index, task in ipairs(peers) do
    if task.id == ctx.id then
      return peers, index, nil
    end
  end
  return peers, nil, "当前任务不在扫描结果中: " .. tostring(ctx.id)
end

function M.find_peer(direction, opts)
  opts = opts or {}
  local ctx = opts.context or state.context_from_buf(0, opts)
  local peers, index, reason = M.get_peer_tasks(ctx, opts)
  if reason then
    return nil, reason
  end
  local target = index + direction
  if target < 1 then
    return nil, "已经是当前 tag 的第一个任务"
  end
  if target > #peers then
    return nil, "已经是当前 tag 的最后一个任务"
  end
  return peers[target], nil
end

function M.goto_peer(direction, opts)
  local target, reason = M.find_peer(direction, opts)
  if not target then
    notify(reason or "无法定位相邻任务", vim.log.levels.WARN)
    return false
  end
  return edit(target.plan_file)
end

function M.next_task(opts)
  return M.goto_peer(1, opts)
end

function M.previous_task(opts)
  return M.goto_peer(-1, opts)
end

function M.counterpart_path(ctx, opts)
  opts = opts or {}
  ctx = ctx or state.context_from_buf(0, opts)
  local reason = M.unavailable_reason(ctx)
  if reason then
    return nil, reason
  end
  if ctx.kind == "plan" then
    if not exists(ctx.todo_file) then
      return nil, "TODO 文件不存在: " .. tostring(ctx.todo_file)
    end
    return ctx.todo_file, nil
  end
  if ctx.kind == "todo" then
    if not exists(ctx.plan_file) then
      return nil, "plan 文件不存在: " .. tostring(ctx.plan_file)
    end
    return ctx.plan_file, nil
  end
  return nil, "无法识别当前 TaskAdmin 核心文档"
end

function M.toggle_todo(opts)
  local path, reason = M.counterpart_path(nil, opts)
  if not path then
    notify(reason or "无法定位 plan/TODO", vim.log.levels.WARN)
    return false
  end
  return edit(path)
end

return M
