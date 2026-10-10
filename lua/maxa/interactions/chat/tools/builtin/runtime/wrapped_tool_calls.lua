-- Utilities for interpreting builtin wrapper calls as semantic inner calls.
--
-- Direct and wrapped `load` calls must be visible to history, compaction and
-- reload deduplication in the same way. This module expands:
--   - load(...)
--   - call(tool="load", params={...})
--   - multicall(calls={{tool="load", ...}})
-- into a normalized list of semantic calls while keeping the outer call_id that
-- owns the actual tool result.

local M = {}

local function decode_arguments(arguments)
  if type(arguments) == "table" then
    return arguments
  end
  if type(arguments) ~= "string" or arguments == "" then
    return nil
  end
  local ok, parsed = pcall(vim.json.decode, arguments)
  if ok and type(parsed) == "table" then
    return parsed
  end
  return nil
end

local function decode_params(params)
  if type(params) == "table" then
    return params
  end
  if type(params) == "string" and params ~= "" then
    local ok, parsed = pcall(vim.json.decode, params)
    if ok and type(parsed) == "table" then
      return parsed
    end
  end
  return {}
end

function M.get_call_id(call)
  return call and (call.call_id or call.id) or nil
end

function M.get_call_function(call)
  local func = call and (call["function"] or {}) or {}
  return func.name or (call and call.name), func.arguments or (call and call.arguments)
end

function M.expand_call(call)
  local call_id = M.get_call_id(call)
  local outer_tool_name, arguments = M.get_call_function(call)
  local args = decode_arguments(arguments) or {}
  local expanded = {}

  local function add(tool_name, tool_args, extra)
    if type(tool_name) ~= "string" or tool_name == "" then
      return
    end
    extra = extra or {}
    table.insert(expanded, {
      call_id = call_id,
      tool_name = tool_name,
      args = tool_args or {},
      outer = extra.outer == true,
      outer_tool_name = extra.outer_tool_name,
      label = extra.label,
      index = extra.index,
    })
  end

  if outer_tool_name == "run" and args.scope == "tool" and type(args.command) == "string" then
    add(args.command, decode_params(args.args), { outer = true, outer_tool_name = outer_tool_name })
  elseif outer_tool_name == "call" and type(args.tool) == "string" then
    add(args.tool, decode_params(args.params), {
      outer = true,
      outer_tool_name = outer_tool_name,
    })
  elseif outer_tool_name == "multicall" and type(args.calls) == "table" then
    for index, child in ipairs(args.calls) do
      if type(child) == "table" and type(child.tool) == "string" then
        add(child.tool, decode_params(child.params), {
          outer = true,
          outer_tool_name = outer_tool_name,
          label = child.label,
          index = index,
        })
      end
    end
  else
    add(outer_tool_name, args, { outer = false })
  end

  return expanded
end

function M.iter_message_calls(msg)
  local calls = nil
  if msg and msg.tools and msg.tools.calls then
    calls = msg.tools.calls
  elseif msg and msg.tool_calls then
    calls = msg.tool_calls
  end

  local expanded = {}
  for _, call in ipairs(calls or {}) do
    for _, semantic in ipairs(M.expand_call(call)) do
      table.insert(expanded, semantic)
    end
  end
  return expanded
end

function M.loaded_value(tool_name, args)
  args = args or {}
  if tool_name == "load" then
    return "load", args.target
  end
  return nil, nil
end

function M.context_ids_for_loaded_call(tool_name, args)
  args = args or {}
  local ids = {}
  if tool_name == "load" and type(args.target) == "string" then
    local target = args.target
    local ok, catalog = pcall(require, "maxa.abilities.catalog")
    if ok and catalog.valid_identifier(target) then
      table.insert(ids, "ability:revision:" .. target)
      table.insert(ids, "ability:instructions:" .. target)
      table.insert(ids, "ability:guidance:" .. target)
    elseif target:sub(1, 1) == "#" then
      if ok and catalog.parse_reference(target) then
        table.insert(ids, "ability:reference:file:" .. target)
        table.insert(ids, "ability:reference:resource:" .. target)
      end
    else
      local abs = vim.fn.fnamemodify(target, ":p")
      table.insert(ids, abs)
      if abs ~= target then
        table.insert(ids, target)
      end
    end
  end
  return ids
end

return M
