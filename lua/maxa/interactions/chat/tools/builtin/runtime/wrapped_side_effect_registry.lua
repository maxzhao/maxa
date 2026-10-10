-- Registry for wrapped builtin side effects keyed by the visible wrapper call.
local M = {}

local stack = {}
local pending = {}

local SIDE_EFFECT_TOOLS = {
  load = true,
}

local function current_tool_call_id(context)
  return context and context.tool_call_id
end

function M.is_side_effect_tool(tool_name)
  return SIDE_EFFECT_TOOLS[tool_name] == true
end

function M.current()
  return stack[#stack]
end

function M.context_for(context, inner_tool_name, opts)
  opts = opts or {}
  if not M.is_side_effect_tool(inner_tool_name) then
    return nil
  end
  local outer_call_id = opts.outer_call_id or current_tool_call_id(context)
  if not outer_call_id or outer_call_id == "" then
    return nil
  end
  return {
    outer_call_id = outer_call_id,
    outer_tool_name = opts.outer_tool_name,
    inner_tool_name = inner_tool_name,
    label = opts.label,
    index = opts.index,
  }
end

function M.with_context(ctx, fn)
  if type(ctx) ~= "table" then
    return fn()
  end
  table.insert(stack, ctx)
  local ok, a, b, c, d = pcall(fn)
  table.remove(stack)
  if not ok then
    error(a)
  end
  return a, b, c, d
end

local function ensure_entry(outer_call_id)
  if not outer_call_id or outer_call_id == "" then
    return nil
  end
  pending[outer_call_id] = pending[outer_call_id] or { tools = {} }
  return pending[outer_call_id]
end

function M.record_tool(tool_name, metadata)
  local ctx = M.current()
  if not ctx or not ctx.outer_call_id then
    return false
  end
  local entry = ensure_entry(ctx.outer_call_id)
  if not entry then
    return false
  end
  table.insert(entry.tools, vim.tbl_extend("force", {
    tool_name = tool_name or ctx.inner_tool_name,
    outer_tool_name = ctx.outer_tool_name,
    label = ctx.label,
    index = ctx.index,
  }, metadata or {}))
  return true
end

function M.peek(outer_call_id)
  return outer_call_id and pending[outer_call_id] or nil
end

function M.take(outer_call_id)
  if not outer_call_id or outer_call_id == "" then
    return nil
  end
  local entry = pending[outer_call_id]
  pending[outer_call_id] = nil
  return entry
end

function M.clear(outer_call_id)
  if outer_call_id then
    pending[outer_call_id] = nil
  end
end

return M
