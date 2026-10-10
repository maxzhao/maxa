-- Cooperative cancellation bridge for builtin async wrapper calls.
--
-- call / multicall can finish their outer async
-- task immediately on cancel, but inner Native MCP tools need a cooperative
-- path to stop their own side effects. This module provides a session-local
-- context stack so inner tools can register cancellable handles while they are
-- dispatched through an async wrapper.

local M = {}

---@type table[]
local stack = {}

---@type table<string, table>
local states = {}

local function state_for(async_id)
  if async_id == nil or tostring(async_id) == "" then
    return nil
  end
  async_id = tostring(async_id)
  states[async_id] = states[async_id] or {
    handles = {},
    cancelled = false,
    reason = nil,
  }
  return states[async_id]
end

local function call_handle_cancel(handle, reason)
  if type(handle) ~= "table" or type(handle.cancel) ~= "function" then
    return false
  end
  if handle._builtin_cancel_called == true then
    return false
  end
  handle._builtin_cancel_called = true
  local ok, err = pcall(handle.cancel, reason)
  if not ok then
    handle.cancel_error = tostring(err)
  end
  return ok
end

function M.with_context(ctx, fn)
  if type(ctx) ~= "table" or not (ctx.async_id or ctx.register) or type(fn) ~= "function" then
    return fn()
  end
  state_for(ctx.async_id)
  table.insert(stack, ctx)
  local ok, a, b, c, d = pcall(fn)
  table.remove(stack)
  if not ok then
    error(a)
  end
  return a, b, c, d
end

function M.current()
  return stack[#stack]
end

function M.register_handle(handle)
  local ctx = M.current()
  if not ctx or type(handle) ~= "table" or type(handle.cancel) ~= "function" then
    return false
  end
  -- A foreground native member owns handles only until its invocation settles.
  -- Independent async tasks install their own inner async_id context as before.
  if ctx.register then return ctx.register(handle) end
  if not ctx.async_id then return false end

  local state = state_for(ctx.async_id)
  if not state then
    return false
  end

  handle.async_id = handle.async_id or ctx.async_id
  handle.outer_tool_name = handle.outer_tool_name or ctx.outer_tool_name
  handle.inner_tool_name = handle.inner_tool_name or ctx.inner_tool_name
  handle.label = handle.label or ctx.label
  handle.index = handle.index or ctx.index

  table.insert(state.handles, handle)

  if state.cancelled then
    call_handle_cancel(handle, state.reason or "Async wrapper task cancelled.")
  end

  return true
end

function M.cancel(async_id, reason)
  if async_id == nil or tostring(async_id) == "" then
    return { cancelled = 0, errors = {} }
  end
  local state = state_for(async_id)
  if not state then
    return { cancelled = 0, errors = {} }
  end

  state.cancelled = true
  state.reason = reason or "Async wrapper task cancelled."

  local cancelled = 0
  local errors = {}
  for _, handle in ipairs(state.handles) do
    local ok = call_handle_cancel(handle, state.reason)
    if ok then
      cancelled = cancelled + 1
    elseif handle.cancel_error then
      table.insert(errors, handle.cancel_error)
    end
  end

  return {
    cancelled = cancelled,
    errors = errors,
  }
end

function M.is_cancelled(async_id)
  local state = async_id and states[tostring(async_id)] or nil
  return state and state.cancelled == true or false
end

function M.clear(async_id)
  if async_id ~= nil then
    states[tostring(async_id)] = nil
  end
end

function M._states()
  return states
end

function M._reset()
  stack = {}
  states = {}
end

return M
