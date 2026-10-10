-- filepath: lua/maxa/task_browser/picker.lua
-- Snacks picker integration for browsing TaskAdmin tasks.

local scanner = require("maxa.task_browser.scanner")
local state = require("maxa.task_browser.state")

local M = {}

local ALL_TAGS = "*"

local function notify(message, level)
  vim.notify(message, level or vim.log.levels.INFO, { title = "TaskAdmin Browser" })
end

local function exists(path)
  return type(path) == "string" and path ~= "" and vim.uv.fs_stat(path) ~= nil
end

local function json_value(value)
  return value ~= vim.NIL and value or nil
end

local function edit(path)
  if not exists(path) then
    notify("文件不存在: " .. tostring(path), vim.log.levels.WARN)
    return false
  end
  vim.cmd.edit(vim.fn.fnameescape(path))
  return true
end

local function status_rank(status)
  local ranks = {
    ["in-progress"] = 1,
    pending = 2,
    review = 3,
    deferred = 4,
    cancelled = 5,
    done = 6,
  }
  return ranks[status] or 99
end

local function display_for_task(task)
  local priority = task.priority or "-"
  return string.format("%-6s %-11s %-6s %s", task.id, task.status or "unknown", priority, task.name or "")
end

local function text_for_task(task)
  return table.concat({
    task.id or "",
    task.name or "",
    task.description or "",
    task.status or "",
    task.priority or "",
    task.tag or "",
  }, " ")
end

local function normalize_opts(opts)
  opts = vim.tbl_deep_extend("force", {}, opts or {})
  if opts.tag == "all" or opts.tag == "ALL" or opts.tag == ALL_TAGS then
    opts.tag = ALL_TAGS
    opts.all_tags = true
  end
  if opts.all_tags then
    opts.tag = ALL_TAGS
  end
  opts.active_tag = opts.active_tag or state.get_active_tag(opts)
  opts.tag = opts.tag or opts.active_tag
  return opts
end

local function title_for_opts(opts)
  opts = normalize_opts(opts)
  local tag_label = opts.all_tags and "all tags" or opts.tag
  local title = "TaskAdmin Tasks [" .. tag_label .. "]"
  if opts.status then
    title = title .. " status:" .. opts.status
  end
  return title
end

local function sorted_tags(opts)
  local tags = state.list_tags(opts)
  local active = opts.active_tag or state.get_active_tag(opts)
  local seen = {}
  local result = { active }
  seen[active] = true
  for _, tag in ipairs(tags) do
    if not seen[tag] then
      table.insert(result, tag)
      seen[tag] = true
    end
  end
  table.insert(result, ALL_TAGS)
  return result
end

local function next_in_cycle(values, current)
  if #values == 0 then
    return nil
  end
  for index, value in ipairs(values) do
    if value == current then
      return values[index % #values + 1]
    end
  end
  return values[1]
end

---@param opts table|nil
---@return table
function M.normalize_opts(opts)
  return normalize_opts(opts)
end

---@param opts table|nil
---@return string
function M.title(opts)
  return title_for_opts(opts)
end

---@param task table
---@return table
function M.item_from_task(task)
  local display = display_for_task(task)
  return {
    id = task.id,
    task = task,
    tag = task.tag,
    status = task.status,
    priority = task.priority,
    file = task.plan_file,
    plan_file = task.plan_file,
    todo_file = task.todo_file,
    text = text_for_task(task),
    display = display,
    name = task.name,
  }
end

---@param opts table|nil
---@return table[]
function M.items(opts)
  opts = normalize_opts(opts)
  local tags = opts.all_tags and state.list_tags(opts) or { opts.tag }
  local status = opts.status
  local items = {}

  for _, tag in ipairs(tags) do
    local result = scanner.scan(tag, opts)
    for _, task in ipairs(result.tasks or {}) do
      if not status or task.status == status then
        table.insert(items, M.item_from_task(task))
      end
    end
  end

  table.sort(items, function(a, b)
    local task_a = a.task or {}
    local task_b = b.task or {}
    if tostring(task_a.tag) ~= tostring(task_b.tag) then
      return tostring(task_a.tag) < tostring(task_b.tag)
    end
    if status_rank(task_a.status) ~= status_rank(task_b.status) then
      return status_rank(task_a.status) < status_rank(task_b.status)
    end
    return state.compare_ids(task_a.id, task_b.id)
  end)

  return items
end

---@param item table
---@return table
function M.format_item(item)
  local task = item.task or {}
  local id_hl = "SnacksPickerLabel"
  local status_hl = task.status == "done" and "DiagnosticOk"
    or task.status == "in-progress" and "DiagnosticInfo"
    or task.status == "review" and "DiagnosticWarn"
    or task.status == "cancelled" and "DiagnosticError"
    or "SnacksPickerComment"
  return {
    { string.format("%-6s", task.id or ""), id_hl, field = "id" },
    { " " },
    { string.format("%-11s", task.status or "unknown"), status_hl, field = "status" },
    { " " },
    { string.format("%-6s", task.priority or "-"), "SnacksPickerComment", field = "priority" },
    { " " },
    { task.name or "", "SnacksPickerFile", field = "name" },
    { " [" .. tostring(task.tag or "") .. "]", "SnacksPickerComment", field = "tag" },
  }
end

---@param picker table
---@param item table|nil
---@return boolean
function M.open_task(picker, item)
  item = item or (picker and picker:current())
  if not item then
    return false
  end
  if picker then
    picker:close()
  end
  return edit(item.plan_file or item.file)
end

---@param picker table
---@param item table|nil
---@return boolean
function M.open_todo(picker, item)
  item = item or (picker and picker:current())
  if not item then
    return false
  end
  if not exists(item.todo_file) then
    notify("TODO 文件不存在: " .. tostring(item.todo_file), vim.log.levels.WARN)
    return false
  end
  if picker then
    picker:close()
  end
  return edit(item.todo_file)
end

---@param picker table
---@param item table|nil
---@return boolean
function M.copy_id(picker, item)
  item = item or (picker and picker:current())
  if not item or not item.id then
    return false
  end
  vim.fn.setreg("+", item.id)
  vim.fn.setreg('"', item.id)
  notify("已复制任务 ID: " .. item.id)
  return true
end

---@param picker table
---@param opts table
function M.apply_filter(picker, opts)
  opts = normalize_opts(opts)
  picker.opts.task_browser = opts
  picker.opts.items = M.items(opts)
  picker.title = title_for_opts(opts)
  if picker.list and picker.list.set_target then
    picker.list:set_target()
  end
  if picker.find then
    picker:find({ refresh = true })
  end
end

---@param picker table
---@return boolean
function M.cycle_status(picker)
  if not picker then
    return false
  end
  local opts = normalize_opts(picker.opts.task_browser or {})
  local values = vim.list_extend({ nil }, state.STATUS_VALUES)
  opts.status = next_in_cycle(values, opts.status)
  M.apply_filter(picker, opts)
  notify("状态过滤: " .. (opts.status or "all"))
  return true
end

---@param picker table
---@return boolean
function M.cycle_tag(picker)
  if not picker then
    return false
  end
  local opts = normalize_opts(picker.opts.task_browser or {})
  local next_tag = next_in_cycle(sorted_tags(opts), opts.all_tags and ALL_TAGS or opts.tag)
  opts.all_tags = next_tag == ALL_TAGS
  opts.tag = next_tag
  M.apply_filter(picker, opts)
  notify("Tag 过滤: " .. (opts.all_tags and "all tags" or opts.tag))
  return true
end

---@param picker table
---@return boolean
function M.clear_filters(picker)
  if not picker then
    return false
  end
  local opts = normalize_opts(picker.opts.task_browser or {})
  opts.status = nil
  opts.all_tags = nil
  opts.tag = opts.active_tag or state.get_active_tag(opts)
  M.apply_filter(picker, opts)
  notify("已清除 TaskAdmin 过滤")
  return true
end

---@param picker table
---@return boolean
function M.refresh(picker)
  scanner.clear_cache()
  if picker then
    M.apply_filter(picker, picker.opts.task_browser or {})
  end
  notify("TaskAdmin browser cache refreshed")
  return true
end

---@param next_task table
---@param tag string
---@param opts table|nil
---@return table
function M.item_from_next_task(next_task, tag, opts)
  if type(next_task) ~= "table" then
    return nil
  end

  local id = tostring(json_value(next_task.id) or "")
  local paths = state.paths_for_id(tag, id, opts) or {}
  local task = {
    id = id,
    tag = tag,
    task_dir = json_value(next_task.task_dir) or paths.task_dir,
    meta_file = json_value(next_task.meta_file) or paths.meta_file,
    plan_file = json_value(next_task.plan_file) or paths.plan_file,
    todo_file = json_value(next_task.todo_file) or paths.todo_file,
    name = json_value(next_task.name) or "",
    description = json_value(next_task.description) or "",
    status = json_value(next_task.status) or "next",
    priority = json_value(next_task.priority),
  }
  return M.item_from_task(task)
end

---@param opts table|nil
---@return table[]|nil items
---@return string|nil error
function M.next_task_items(opts)
  opts = opts or {}
  local ok, result = state.get_next_task(opts)
  if not ok then
    return nil, tostring(result)
  end
  local next_task = json_value(result.next_task)
  if not next_task then
    return {}, nil
  end
  local tag = json_value(result.tag) or opts.tag or state.get_active_tag(opts)
  local item = M.item_from_next_task(next_task, tag, opts)
  if not item then
    return nil, "next_task 输出格式无效"
  end
  return { item }, nil
end

---@param opts table|nil
---@return table|nil
function M.open_next_tasks(opts)
  opts = opts or {}
  local items, err = M.next_task_items(opts)
  if not items then
    notify("无法获取下一个可执行任务: " .. tostring(err), vim.log.levels.ERROR)
    return nil
  end
  if #items == 0 then
    notify("没有可执行的下一个任务", vim.log.levels.INFO)
    return nil
  end

  return M.open(vim.tbl_deep_extend("force", opts, {
    snacks = {
      title = "TaskAdmin Next Task",
      items = items,
    },
  }))
end

---@param opts table|nil
---@return table
function M.picker_opts(opts)
  opts = normalize_opts(opts)

  return vim.tbl_deep_extend("force", {
    source = "task_browser_tasks",
    title = title_for_opts(opts),
    task_browser = opts,
    items = M.items(opts),
    format = function(item)
      return M.format_item(item)
    end,
    confirm = function(picker, item)
      return M.open_task(picker, item)
    end,
    actions = {
      task_browser_open_todo = function(picker, item)
        return M.open_todo(picker, item)
      end,
      task_browser_copy_id = function(picker, item)
        return M.copy_id(picker, item)
      end,
      task_browser_cycle_status = function(picker)
        return M.cycle_status(picker)
      end,
      task_browser_cycle_tag = function(picker)
        return M.cycle_tag(picker)
      end,
      task_browser_clear_filters = function(picker)
        return M.clear_filters(picker)
      end,
      task_browser_refresh = function(picker)
        return M.refresh(picker)
      end,
    },
    win = {
      input = {
        keys = {
          ["<C-p>"] = { "task_browser_open_todo", mode = { "i", "n" }, desc = "Open TODO" },
          ["<C-y>"] = { "task_browser_copy_id", mode = { "i", "n" }, desc = "Copy task ID" },
          ["<M-s>"] = { "task_browser_cycle_status", mode = { "i", "n" }, desc = "Cycle status filter" },
          ["<M-t>"] = { "task_browser_cycle_tag", mode = { "i", "n" }, desc = "Cycle tag filter" },
          ["<M-a>"] = { "task_browser_clear_filters", mode = { "i", "n" }, desc = "Clear filters" },
          ["<M-r>"] = { "task_browser_refresh", mode = { "i", "n" }, desc = "Refresh tasks" },
        },
      },
      list = {
        keys = {
          ["p"] = { "task_browser_open_todo", desc = "Open TODO" },
          ["y"] = { "task_browser_copy_id", desc = "Copy task ID" },
          ["s"] = { "task_browser_cycle_status", desc = "Cycle status filter" },
          ["t"] = { "task_browser_cycle_tag", desc = "Cycle tag filter" },
          ["a"] = { "task_browser_clear_filters", desc = "Clear filters" },
          ["r"] = { "task_browser_refresh", desc = "Refresh tasks" },
        },
      },
    },
  }, opts.snacks or {})
end

---@param opts table|nil
---@return table|nil
function M.open(opts)
  local ok, snacks = pcall(require, "snacks")
  if not ok or not snacks.picker then
    notify("Snacks picker 不可用", vim.log.levels.ERROR)
    return nil
  end
  return snacks.picker(M.picker_opts(opts))
end

return M
