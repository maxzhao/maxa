-- Canonical tool-call validation and bounded model feedback.
local adapters = require("maxa.adapters")

local M = {}

local FIELD_LIMIT = 250
local SNAPSHOT_LIMIT = 1000
local SNAPSHOT_MARKER = "…[snapshot truncated]"
local DEPTH_LIMIT = 32
local NODE_LIMIT = 1000

local function is_valid_utf8(value)
  local index = 1
  while index <= #value do
    local byte = value:byte(index)
    local sequence_length
    if byte <= 0x7F then
      sequence_length = 1
    elseif byte >= 0xC2 and byte <= 0xDF then
      sequence_length = 2
    elseif byte >= 0xE0 and byte <= 0xEF then
      sequence_length = 3
    elseif byte >= 0xF0 and byte <= 0xF4 then
      sequence_length = 4
    else
      return false
    end
    for offset = 2, sequence_length do
      local continuation = value:byte(index + offset - 1)
      if not continuation or continuation < 0x80 or continuation > 0xBF then
        return false
      end
    end
    local second = value:byte(index + 1)
    if
      (byte == 0xE0 and second < 0xA0)
      or (byte == 0xED and second > 0x9F)
      or (byte == 0xF0 and second < 0x90)
      or (byte == 0xF4 and second > 0x8F)
    then
      return false
    end
    index = index + sequence_length
  end
  return true
end

local function utf8_text(value)
  value = tostring(value or "")
  if is_valid_utf8(value) then
    return value
  end
  return string.format("[invalid UTF-8; received %d bytes]", #value)
end

local function unicode_len(value)
  return vim.fn.strchars(utf8_text(value))
end

local function unicode_prefix(value, limit)
  return vim.fn.strcharpart(utf8_text(value), 0, limit)
end

local function bounded_writer(limit)
  local marker_length = unicode_len(SNAPSHOT_MARKER)
  local parts = {}
  local used = 0
  local truncated = false

  local function append(value)
    if truncated then
      return false
    end
    value = utf8_text(value)
    local length = unicode_len(value)
    if used + length <= limit then
      parts[#parts + 1] = value
      used = used + length
      return true
    end

    local body_limit = math.max(0, limit - marker_length)
    local current = table.concat(parts)
    if used >= body_limit then
      parts = { unicode_prefix(current, body_limit) }
    else
      parts[#parts + 1] = unicode_prefix(value, body_limit - used)
    end
    used = body_limit
    truncated = true
    return false
  end

  local function result()
    local value = table.concat(parts)
    if truncated then
      value = value .. SNAPSHOT_MARKER
    end
    return unicode_prefix(value, limit)
  end

  return append, result, function()
    return truncated
  end
end

local function json_quote(value)
  local ok, encoded = pcall(vim.json.encode, tostring(value or ""))
  return ok and encoded or '"[unencodable text]"'
end

local function scalar_text(value)
  value = utf8_text(value)
  local length = unicode_len(value)
  if length <= FIELD_LIMIT then
    return value
  end
  return unicode_prefix(value, FIELD_LIMIT) .. string.format("…[field truncated; received %d chars]", length)
end

local function structured_snapshot(value)
  local append, finish, is_truncated = bounded_writer(SNAPSHOT_LIMIT)
  local nodes = 0

  local function encode(item, depth)
    if is_truncated() then
      return
    end
    nodes = nodes + 1
    if nodes > NODE_LIMIT then
      append(json_quote("[node limit reached]"))
      return
    end
    if depth > DEPTH_LIMIT then
      append(json_quote("[depth limit reached]"))
      return
    end

    local kind = type(item)
    if item == vim.NIL or kind == "nil" then
      append("null")
    elseif kind == "string" then
      append(json_quote(scalar_text(item)))
    elseif kind == "number" or kind == "boolean" then
      append(tostring(item))
    elseif kind ~= "table" then
      append(json_quote(scalar_text(item)))
    elseif vim.islist(item) then
      if not append("[") then
        return
      end
      for index, child in ipairs(item) do
        if index > 1 and not append(",") then
          return
        end
        encode(child, depth + 1)
        if is_truncated() then
          return
        end
      end
      append("]")
    else
      if not append("{") then
        return
      end
      local keys = vim.tbl_keys(item)
      table.sort(keys, function(a, b)
        return tostring(a) < tostring(b)
      end)
      for index, key in ipairs(keys) do
        if index > 1 and not append(",") then
          return
        end
        if not append(json_quote(scalar_text(key))) or not append(":") then
          return
        end
        encode(item[key], depth + 1)
        if is_truncated() then
          return
        end
      end
      append("}")
    end
  end

  encode(value, 0)
  return finish()
end

local function raw_snapshot(args, parse_reason)
  local append, finish = bounded_writer(SNAPSHOT_LIMIT)
  local valid_utf8 = is_valid_utf8(args)
  local received = valid_utf8 and vim.fn.strchars(args) or #args
  local unit = valid_utf8 and "chars" or "bytes"
  local reason = scalar_text(parse_reason or "Invalid JSON format")
  append(string.format("[invalid JSON; received %d %s; reason: %s]\n", received, unit, reason))
  append(args)
  return finish()
end

---@param args any
---@param decoded any|nil
---@param parse_reason string|nil
---@return string snapshot
---@return integer|nil received_chars
function M.snapshot(args, decoded, parse_reason)
  if type(args) == "string" then
    local received_chars = is_valid_utf8(args) and vim.fn.strchars(args) or nil
    if decoded ~= nil then
      return structured_snapshot(decoded), received_chars
    end
    return raw_snapshot(args, parse_reason), received_chars
  end
  return structured_snapshot(args), nil
end

local function schema_for(chat, tool_name)
  local registry = chat and chat.tool_registry
  local schemas = registry and registry.schemas
  local schema = schemas and schemas["<tool>" .. tostring(tool_name or "") .. "</tool>"]
  if type(schema) ~= "table" then
    return nil
  end
  local fn = type(schema["function"]) == "table" and schema["function"] or schema
  return fn.parameters or fn.inputSchema or schema.inputSchema
end

local function missing_required(parameters, decoded)
  local missing = {}
  for _, name in ipairs(type(parameters) == "table" and parameters.required or {}) do
    if decoded[name] == nil then
      missing[#missing + 1] = name
    end
  end
  return missing
end

local function replayability(adapter, call)
  local ok, replayable, reason = pcall(adapters.call_handler, adapter, "can_replay_call", call)
  if not ok then
    return false, "Current adapter rejected replayability inspection"
  end
  return replayable, reason
end

local function specific_advice(tool_name)
  if tool_name == "write" then
    return "Use `edit` with smaller SEARCH/REPLACE blocks; for a new file, write a small skeleton first."
  elseif tool_name == "edit" then
    return "Split the change into sequential `edit` calls with one small SEARCH/REPLACE block each."
  elseif tool_name == "run" then
    return "Break the command into smaller steps and use intermediate files instead of embedding large content."
  elseif tool_name == "lua" then
    return "Split the Lua code into smaller calls focused on one operation each."
  end
end

local function feedback(entry, protocol_error)
  local lines = {
    "TOOL_CALL_ERROR",
    "Tool: " .. (entry.tool_name ~= "" and entry.tool_name or "[missing]"),
    "Status: rejected_before_execution",
    "Reason: " .. entry.reason,
  }
  if
    entry.reason_code == "invalid_json"
    or entry.reason_code == "missing_required"
    or entry.reason_code == "incomplete_call"
  then
    lines[#lines + 1] = "Likely cause: The tool arguments were truncated when model output reached its token limit."
  end
  if entry.received_chars ~= nil then
    lines[#lines + 1] = "Received characters: " .. tostring(entry.received_chars)
  end
  lines[#lines + 1] = "Received parameters:"
  lines[#lines + 1] = entry.snapshot
  if protocol_error then
    lines[#lines + 1] =
      "The malformed structured call was removed because the current adapter cannot replay it unchanged."
  end
  lines[#lines + 1] =
    "Action: Reduce or split the arguments, compare them with the tool schema, and retry. The tool was not executed."
  local advice = specific_advice(entry.tool_name)
  if advice then
    lines[#lines + 1] = "Tool-specific advice: " .. advice
  end
  return table.concat(lines, "\n")
end

local function fire_tool_call_error(chat_bufnr, entry)
  if not chat_bufnr then
    return
  end
  local fire_ok, fire = pcall(require, "maxa.abilities.hooks.fire")
  if fire_ok then
    fire.fire("ToolCallError", {
      bufnr = chat_bufnr,
      tool_id = entry.tool_name,
      reason = entry.reason,
      params = entry.snapshot,
    })
  end
end

---@param tools MaxaAI.Tools
---@param chat MaxaAI.Chat
---@param call table
---@param index integer
---@return table
function M.classify(tools, chat, call, index)
  local fn = type(call) == "table" and call["function"] or nil
  local tool_name = type(fn) == "table" and fn.name or nil
  local args = type(fn) == "table" and fn.arguments or nil
  local reason_code, reason, decoded, parse_reason

  if type(tool_name) ~= "string" or tool_name == "" then
    reason_code = "missing_name"
    reason = "Missing tool name"
  elseif type(args) ~= "string" then
    reason_code = "invalid_arguments_type"
    reason = string.format("Arguments must be a JSON string, but got %s", type(args))
  elseif args == "" then
    decoded = vim.empty_dict()
  else
    local ok, value = pcall(vim.json.decode, args)
    if not ok then
      reason_code = "invalid_json"
      parse_reason = tostring(value)
      reason = "Invalid JSON format"
    elseif type(value) ~= "table" then
      reason_code = "invalid_arguments_shape"
      reason = string.format("Expected object/table but got %s", type(value))
      decoded = value
    else
      decoded = value
    end
  end

  if not reason_code and call._status ~= nil and call._status ~= "completed" then
    reason_code = "incomplete_call"
    reason = "The provider reported an incomplete function call"
  end

  if not reason_code and decoded ~= nil then
    local missing = missing_required(schema_for(chat, tool_name), decoded)
    if #missing > 0 then
      reason_code = "missing_required"
      reason =
        string.format("Missing required parameter%s: %s", #missing == 1 and "" or "s", table.concat(missing, ", "))
    end
  end

  if not reason_code and decoded ~= nil then
    local schema = schema_for(chat, tool_name)
    if schema then
      local check = require("maxa.interactions.chat.tools.schema_validation")
      local valid, err = check.validate(schema, decoded)
      if not valid then
        reason_code = err.schema_error and "invalid_schema" or "invalid_parameters"
        reason = check.format_error(err)
      end
    end
  end

  local adapter_replayable, adapter_reason = replayability(tools and tools.adapter, call)
  if not reason_code and adapter_replayable ~= true then
    reason_code = "unreplayable_structure"
    reason = tostring(adapter_reason or "Current adapter cannot replay this tool call unchanged")
  end

  if not reason_code then
    return {
      kind = "valid",
      index = index,
      call = call,
      tool_name = tool_name,
    }
  end

  local snapshot, received_chars = M.snapshot(args, decoded, parse_reason)
  local kind = adapter_replayable == true and "rejected_replayable" or "rejected_unreplayable"
  local entry = {
    kind = kind,
    index = index,
    call = call,
    tool_name = type(tool_name) == "string" and tool_name or "",
    reason_code = reason_code,
    reason = reason,
    snapshot = snapshot,
    received_chars = received_chars,
  }
  entry.feedback = feedback(entry, kind == "rejected_unreplayable")
  return entry
end

---@param tools MaxaAI.Tools
---@param chat MaxaAI.Chat
---@param calls table[]
---@return table
function M.classify_batch(tools, chat, calls, opts)
  local plan = {
    calls = calls or {},
    entries = {},
    history_calls = {},
    corrections = {},
  }
  for index, call in ipairs(plan.calls) do
    -- Only the runtime runs expander supplies execution defaults. Keep the
    -- canonical call unchanged for history, transport and presentation.
    local execution_params = opts and opts.expanded_runs and opts.execution_params and opts.execution_params[index]
    local validation_call = call
    if execution_params then
      validation_call = vim.deepcopy(call)
      validation_call["function"].arguments = vim.json.encode(execution_params)
    end
    local entry = M.classify(tools, chat, validation_call, index)
    entry.call, entry.execution_params = call, execution_params
    plan.entries[#plan.entries + 1] = entry
    if entry.kind ~= "rejected_unreplayable" then
      plan.history_calls[#plan.history_calls + 1] = call
    else
      plan.corrections[#plan.corrections + 1] = entry
    end
  end
  local declarations = {}
  for index, entry in ipairs(plan.entries) do
    if entry.tool_name == "multicall" then declarations[#declarations + 1] = index end
  end
  if #declarations > 0 then
    plan.native_batch = { declaration_index = declarations[1] }
    if #declarations ~= 1 or declarations[1] ~= 1 then
      plan.native_batch.error = "multicall must be the first and unique declaration in the complete model tool batch."
    else
      local declaration = plan.entries[1]
      local decoded = declaration.kind == "valid" and vim.json.decode(declaration.call["function"].arguments) or {}
      if decoded.runs ~= nil and not (opts and opts.expanded_runs) then
        if #plan.calls ~= 1 then plan.native_batch.error = "multicall cannot mix runs with native sibling calls."
        else plan.native_batch.runs = decoded.runs end
      elseif #plan.calls < 2 or #plan.calls > 17 then
        plan.native_batch.error = "multicall requires runs for a single call, or 1–16 native sibling members."
      end
    end
    local seen = {}
    plan.history_calls, plan.corrections = {}, {}
    for _, entry in ipairs(plan.entries) do
      local correlation = type(entry.call) == "table" and (entry.call.call_id or entry.call.id)
      if entry.kind ~= "rejected_unreplayable" and correlation and seen[correlation] then
        entry.kind, entry.reason_code = "rejected_unreplayable", "duplicate_call_id"
        entry.reason = "Duplicate invocation correlation ID in multicall; no member was executed."
        local args = entry.call["function"].arguments
        local ok, decoded = pcall(vim.json.decode, args)
        entry.snapshot, entry.received_chars = M.snapshot(args, ok and decoded or nil)
        entry.feedback = feedback(entry, true)
        plan.native_batch.error = entry.reason
      end
      if entry.kind == "rejected_unreplayable" then
        plan.corrections[#plan.corrections + 1] = entry
      else
        seen[correlation] = true
        plan.history_calls[#plan.history_calls + 1] = entry.call
      end
    end
  end
  return plan
end

---@param plan table
---@param chat_bufnr integer|nil
function M.fire_errors(plan, chat_bufnr)
  for _, entry in ipairs(type(plan) == "table" and plan.entries or {}) do
    if entry.kind ~= "valid" then
      fire_tool_call_error(chat_bufnr, entry)
    end
  end
end

return M
