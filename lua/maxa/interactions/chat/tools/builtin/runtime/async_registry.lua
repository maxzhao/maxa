-- Async task registry for Chat builtin tools.
-- Stores session-local async task state, binds tasks to Maxa AI chats,
-- supports cancellation, and wakes non-busy waiters.

local M = {}

local DEFAULT_RESULT_TTL_MS = 60 * 60 * 1000 -- 1 hour after terminal state
local TERMINAL = {
  succeeded = true,
  failed = true,
  timed_out = true,
  cancelled = true,
}

---@type table<string, table>
local tasks = {}
local counter = 0

local function now_ms()
  return math.floor(vim.uv.now())
end

local function iso_now()
  return os.date("!%Y-%m-%dT%H:%M:%SZ")
end

local function is_terminal(status)
  return TERMINAL[status] == true
end

local function make_id()
  counter = counter + 1
  local hr = tostring(vim.uv.hrtime()):sub(-8)
  return string.format("async_%s_%d_%s", os.date("!%Y%m%d%H%M%S"), counter, hr)
end

local function stop_timer(timer_id)
  if timer_id then
    pcall(vim.fn.timer_stop, timer_id)
  end
end

local function normalize_identity(opts)
  opts = opts or {}
  local chat = opts.chat
  local chat_id = opts.chat_id
  local bufnr = opts.bufnr

  if opts.context then
    local ok, ability_utils = pcall(require, "maxa.interactions.chat.tools.builtin.runtime.ability_utils")
    if ok and ability_utils and type(ability_utils.get_chat_and_agent) == "function" then
      local found_chat = ability_utils.get_chat_and_agent(opts.context)
      if found_chat then
        chat = chat or found_chat
      end
    end
  end

  if type(chat) == "table" then
    if chat_id == nil and chat.id ~= nil then
      chat_id = tostring(chat.id)
    end
    if bufnr == nil and chat.bufnr ~= nil then
      bufnr = tonumber(chat.bufnr)
    end
  end

  if chat_id ~= nil then
    chat_id = tostring(chat_id)
    if chat_id == "" then
      chat_id = nil
    end
  end
  bufnr = tonumber(bufnr)

  return chat_id, bufnr
end

local function task_public(task)
  if not task then
    return nil
  end
  return {
    async_id = task.id,
    status = task.status,
    tool = task.tool,
    label = task.label,
    chat_id = task.chat_id,
    bufnr = task.bufnr,
    submitted_at = task.submitted_at,
    finished_at = task.finished_at,
    elapsed_ms = task.finished_ms and (task.finished_ms - task.started_ms) or (now_ms() - task.started_ms),
    duration_ms = task.finished_ms and (task.finished_ms - task.started_ms) or nil,
  }
end

local function cleanup_waiter(waiter)
  if not waiter then
    return
  end
  if waiter.timer_id then
    stop_timer(waiter.timer_id)
    waiter.timer_id = nil
  end
end

-- Presentation is task-private and never part of task_public/result JSON.
-- Closing the sink cannot change the async terminal latch or block completion.
local function finish_presentation(task, result)
  local sink = task._presentation
  if sink and type(sink._finish) == "function" then pcall(sink._finish, sink, result) end
end

local function notify_waiters(task)
  local waiters = task.waiters or {}
  task.waiters = {}
  for _, waiter in ipairs(waiters) do
    cleanup_waiter(waiter)
    if not waiter.done then
      waiter.done = true
      waiter.callback(task, false)
    end
  end
end

local function schedule_cleanup(task)
  if task.cleanup_timer then
    stop_timer(task.cleanup_timer)
    task.cleanup_timer = nil
  end
  task.cleanup_timer = vim.fn.timer_start(DEFAULT_RESULT_TTL_MS, function()
    local current = tasks[task.id]
    if current and is_terminal(current.status) then
      tasks[task.id] = nil
    end
  end)
end

---@param opts table {tool:string,label:string|nil,context:table|nil,chat:table|nil,chat_id:string|nil,bufnr:number|nil}
---@return table task
function M.create(opts)
  opts = opts or {}
  local chat_id, bufnr = normalize_identity(opts)
  local task = {
    id = make_id(),
    tool = tostring(opts.tool or "unknown"),
    label = tostring(opts.label or opts.tool or "async task"),
    chat_id = chat_id,
    bufnr = bufnr,
    status = "running",
    submitted_at = iso_now(),
    started_ms = now_ms(),
    finished_at = nil,
    finished_ms = nil,
    result = nil,
    error = nil,
    cancel = nil,
    cancel_error = nil,
    waiters = {},
    cleanup_timer = nil,
  }
  tasks[task.id] = task
  if opts.context and opts.context.ui then
    local ok, sink = pcall(function()
      return require("maxa.interactions.chat.tools.display").async_ui(opts.context, task)
    end)
    if ok then task._presentation = sink end
  end
  return task
end

---@param id string
---@return table|nil task
function M.get(id)
  return tasks[id]
end

---@param task table
---@return table
function M.public(task)
  return task_public(task)
end

---@param id string
---@param cancel fun(reason:string|nil)|nil
function M.set_canceller(id, cancel)
  local task = tasks[id]
  if not task or is_terminal(task.status) then
    return false
  end
  task.cancel = cancel
  return true
end

---@param id string
---@param result string
function M.succeed(id, result)
  local task = tasks[id]
  if not task or is_terminal(task.status) then
    return false
  end
  task.status = "succeeded"
  task.result = tostring(result or "")
  task.finished_at = iso_now()
  task.finished_ms = now_ms()
  finish_presentation(task, { ok = true, text = task.result })
  notify_waiters(task)
  schedule_cleanup(task)
  return true
end

---@param id string
---@param error string
---@param status string|nil
function M.fail(id, error, status)
  local task = tasks[id]
  if not task or is_terminal(task.status) then
    return false
  end
  status = status or "failed"
  if not TERMINAL[status] then
    status = "failed"
  end
  task.status = status
  task.error = tostring(error or "Unknown async task error")
  task.finished_at = iso_now()
  task.finished_ms = now_ms()
  finish_presentation(task, { ok = false, text = task.error, status = status })
  notify_waiters(task)
  schedule_cleanup(task)
  return true
end

---@param id string
---@param reason string|nil
---@return boolean ok
---@return table|string task_or_error
function M.cancel(id, reason)
  local task = tasks[id]
  if not task then
    return false, "not_found"
  end
  if is_terminal(task.status) then
    return true, task
  end

  reason = reason or "Async task cancelled."
  if type(task.cancel) == "function" then
    local ok, err = pcall(task.cancel, reason)
    if not ok then
      task.cancel_error = tostring(err)
      reason = reason .. " Canceller error: " .. tostring(err)
    end
  end

  M.fail(id, reason, "cancelled")
  return true, task
end

local function cancel_matching(predicate, reason)
  local cancelled = {}
  for id, task in pairs(tasks) do
    if task and not is_terminal(task.status) and predicate(task) then
      local ok = M.cancel(id, reason)
      if ok then
        table.insert(cancelled, id)
      end
    end
  end
  return cancelled
end

function M.cancel_by_chat(chat_id, reason)
  if chat_id == nil or tostring(chat_id) == "" then
    return {}
  end
  chat_id = tostring(chat_id)
  return cancel_matching(function(task)
    return task.chat_id == chat_id
  end, reason or ("Maxa AI chat closed: " .. chat_id))
end

function M.cancel_by_bufnr(bufnr, reason)
  bufnr = tonumber(bufnr)
  if not bufnr then
    return {}
  end
  return cancel_matching(function(task)
    return tonumber(task.bufnr) == bufnr
  end, reason or ("Maxa AI chat buffer closed: " .. tostring(bufnr)))
end

function M.cancel_all(reason)
  return cancel_matching(function()
    return true
  end, reason or "Neovim is exiting; async task cancelled.")
end

---@param id string
---@return boolean
function M.consume(id)
  local task = tasks[id]
  if not task then
    return false
  end
  if task.cleanup_timer then
    stop_timer(task.cleanup_timer)
  end
  tasks[id] = nil
  return true
end

---@param id string
---@param timeout_ms number|nil
---@param callback fun(task:table|nil, wait_timed_out:boolean)
function M.wait(id, timeout_ms, callback)
  local task = tasks[id]
  if not task then
    return callback(nil, false)
  end
  if is_terminal(task.status) then
    return callback(task, false)
  end

  local waiter = {
    done = false,
    callback = callback,
    timer_id = nil,
  }

  if timeout_ms and timeout_ms > 0 then
    waiter.timer_id = vim.fn.timer_start(timeout_ms, function()
      if waiter.done then
        return
      end
      waiter.done = true
      waiter.timer_id = nil
      -- Remove waiter from task.waiters so completion does not respond twice.
      for i = #(task.waiters or {}), 1, -1 do
        if task.waiters[i] == waiter then
          table.remove(task.waiters, i)
          break
        end
      end
      callback(task, true)
    end)
  end

  table.insert(task.waiters, waiter)
  -- Optional invocation teardown: stop this waiter, not the original task.
  return function()
    if waiter.done then return end
    waiter.done = true
    cleanup_waiter(waiter)
    for i = #task.waiters, 1, -1 do
      if task.waiters[i] == waiter then table.remove(task.waiters, i); break end
    end
  end
end

function M.is_terminal(status)
  return is_terminal(status)
end

function M._tasks()
  return tasks
end

return M
