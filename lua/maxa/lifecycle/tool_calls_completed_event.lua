-- ToolCallsCompleted AbilityHook event support.
--
-- Fires once per MaxaAI tool-call batch after all tool results have been
-- written to chat.messages and around the auto-submit boundary:
--   - inject_at=pre hooks: fired synchronously before auto-submit can continue.
--   - inject_at=post hooks: fired asynchronously after the auto-submit scheduling
--     point, so they do not race to modify the immediate LLM request.
local M = {}

local setup_done = false

local EVENT_NAME = "ToolCallsCompleted"
local BATCH_FIELD = "_ability_hook_tool_calls_completed_batch"
local SEQ_FIELD = "_ability_hook_tool_calls_completed_seq"

local function now_ms()
  return math.floor((vim.uv.hrtime() / 1e6) + 0.5)
end

local function deepcopy(value)
  local ok, copied = pcall(vim.deepcopy, value)
  return ok and copied or value
end

local function decode_json(value)
  if type(value) ~= "string" or value == "" then
    return nil
  end
  local ok, decoded = pcall(vim.json.decode, value)
  if ok then
    return decoded
  end
  return nil
end

local function function_part(call)
  if type(call) ~= "table" then
    return {}
  end
  return type(call["function"]) == "table" and call["function"] or {}
end

local function call_primary_id(call)
  if type(call) ~= "table" then
    return nil
  end
  return call.id or call.call_id
end

local function tool_name_from_call(call)
  local fn = function_part(call)
  return fn.name or call.name or call.tool or ""
end

local function snapshot_call(call, index)
  local fn = function_part(call)
  local raw_args = fn.arguments
  return {
    index = index,
    tool_id = tool_name_from_call(call),
    call_id = call and call.id or nil,
    response_call_id = call and call.call_id or nil,
    arguments_raw = raw_args,
    arguments = decode_json(raw_args),
  }
end

local function snapshot_calls(tools)
  local calls = {}
  local entries = type(tools) == "table" and tools.entries or nil
  if type(entries) == "table" then
    for index, entry in ipairs(entries) do
      local item = snapshot_call(entry.call, index)
      if entry.kind ~= "valid" then
        item.arguments_raw = entry.snapshot
        item.arguments = nil
        item.validation = {
          kind = entry.kind,
          reason = entry.reason,
          reason_code = entry.reason_code,
          received_chars = entry.received_chars,
        }
      end
      table.insert(calls, item)
    end
    return calls
  end
  for index, call in ipairs(tools or {}) do
    table.insert(calls, snapshot_call(call, index))
  end
  return calls
end

local function ids_for_tool(tool)
  local ids = {}
  local fc = tool and tool.function_call or tool
  if type(fc) == "table" then
    if fc.id then
      ids[tostring(fc.id)] = true
    end
    if fc.call_id then
      ids[tostring(fc.call_id)] = true
    end
  end
  return ids
end

local function message_matches_ids(msg, ids)
  if type(msg) ~= "table" or type(msg.tools) ~= "table" then
    return false
  end
  local tools = msg.tools
  return (tools.call_id and ids[tostring(tools.call_id)] == true) or (tools.id and ids[tostring(tools.id)] == true)
end

local function find_result_message(chat, tool)
  local ids = ids_for_tool(tool)
  if not next(ids) then
    return nil
  end
  for i = #(chat.messages or {}), 1, -1 do
    local msg = chat.messages[i]
    if message_matches_ids(msg, ids) then
      return msg
    end
  end
  return nil
end

local function sanitize_message(msg)
  if type(msg) ~= "table" then
    return nil
  end
  return {
    role = msg.role,
    content = msg.content,
    tools = deepcopy(msg.tools),
    _meta = deepcopy(msg._meta),
  }
end

local function normalize_tool_output(tool, for_llm, for_user, result_msg)
  local fc = tool and tool.function_call or tool or {}
  local fn = function_part(fc)
  local raw_args = fn.arguments
  local content = tostring(for_llm or "")
  local validation_snapshot = tool and tool.validation_snapshot
  local validation_entry = tool and tool._maxa_validation_rejection

  return {
    tool_id = tool_name_from_call(fc),
    call_id = fc.id,
    response_call_id = fc.call_id,
    arguments_raw = validation_snapshot or raw_args,
    arguments = validation_snapshot and nil or decode_json(raw_args),
    validation = validation_entry and {
      kind = validation_entry.kind,
      reason = validation_entry.reason,
      reason_code = validation_entry.reason_code,
      received_chars = validation_entry.received_chars,
    } or nil,
    result = {
      content = content,
      content_chars = #content,
      user_content = for_user,
      message = sanitize_message(result_msg),
    },
  }
end

local function maybe_parse_nested_batch(entry)
  if type(entry) ~= "table" or entry.tool_id ~= "multicall" then
    return
  end
  local args = entry.arguments
  local result_text = entry.result and entry.result.content
  local decoded_result = decode_json(result_text)
  local members = type(args) == "table" and args.calls
  if type(members) ~= "table" or type(decoded_result) ~= "table" then
    return
  end
  if type(decoded_result.results) ~= "table" then
    return
  end
  entry.nested_batch = {
    kind = "builtin_multicall",
    call_count = #members,
    calls = deepcopy(members),
    results = deepcopy(decoded_result.results),
  }
end

local function merge_output_into_batch(batch, output)
  if type(batch) ~= "table" or type(output) ~= "table" then
    return
  end

  local key = output.call_id or output.response_call_id or ("index:" .. tostring(#batch.outputs_order + 1))
  key = tostring(key)

  local existing = batch.outputs_by_key[key]
  if not existing then
    existing = {
      tool_id = output.tool_id,
      call_id = output.call_id,
      response_call_id = output.response_call_id,
      arguments_raw = output.arguments_raw,
      arguments = output.arguments,
      validation = output.validation,
      outputs = {},
      result = output.result,
    }
    batch.outputs_by_key[key] = existing
    table.insert(batch.outputs_order, key)
  else
    existing.tool_id = output.tool_id or existing.tool_id
    existing.call_id = output.call_id or existing.call_id
    existing.response_call_id = output.response_call_id or existing.response_call_id
    existing.arguments_raw = output.arguments_raw or existing.arguments_raw
    existing.arguments = output.arguments or existing.arguments
    existing.validation = output.validation or existing.validation
    existing.result = output.result or existing.result
  end

  table.insert(existing.outputs, output.result)
  maybe_parse_nested_batch(existing)
end

local function calls_by_key(calls)
  local map = {}
  for _, call in ipairs(calls or {}) do
    local key = call.call_id or call.response_call_id
    if key then
      map[tostring(key)] = call
    end
  end
  return map
end

local function build_calls(batch)
  local requested = batch.requested_calls or {}
  local requested_by_key = calls_by_key(requested)
  local used = {}
  local calls = {}

  for _, key in ipairs(batch.outputs_order or {}) do
    local output = batch.outputs_by_key[key]
    local base = requested_by_key[key] or {}
    used[key] = true
    local item = vim.tbl_deep_extend("force", {}, base, output or {})
    if output and output.validation then
      item.arguments = nil
    end
    table.insert(calls, item)
  end

  for _, call in ipairs(requested) do
    local key = call.call_id or call.response_call_id
    if key and not used[tostring(key)] then
      table.insert(calls, deepcopy(call))
    elseif not key then
      table.insert(calls, deepcopy(call))
    end
  end

  for index, call in ipairs(calls) do
    call.index = call.index or index
    maybe_parse_nested_batch(call)
  end

  table.sort(calls, function(a, b)
    return (tonumber(a.index) or 0) < (tonumber(b.index) or 0)
  end)

  return calls
end

local function build_payload(chat, batch, tools_finished_data)
  local calls = build_calls(batch)
  local call_count = #calls
  return {
    bufnr = chat.bufnr,
    chat_id = chat.id,
    event_source = "maxa_ai_tools",
    batch_id = tools_finished_data and tools_finished_data.id or batch.local_batch_id,
    local_batch_id = batch.local_batch_id,
    mode = call_count == 1 and "single" or "batch",
    call_count = call_count,
    started_at_ms = batch.started_at_ms,
    completed_at_ms = now_ms(),
    calls = calls,
  }
end

local function get_chat_from_bufnr(bufnr)
  if not bufnr then
    return nil
  end
  local ok, maxa_ai = pcall(require, "maxa")
  if not ok or not maxa_ai.buf_get_chat then
    return nil
  end
  return maxa_ai.buf_get_chat(bufnr)
end

local function fire_completed(chat, batch, tools_finished_data)
  if not chat or not batch then
    return
  end

  local payload = build_payload(chat, batch, tools_finished_data)
  local fire_ok, fire = pcall(require, "maxa.abilities.hooks.fire")
  if not fire_ok then
    return
  end

  -- pre hooks must be in chat.messages before the auto-submit path continues.
  fire.fire_sync(EVENT_NAME, vim.deepcopy(payload))

  -- post hooks are intentionally delayed by one schedule layer before using the
  -- normal async fire(), so MaxaAI's own scheduled auto-submit callback
  -- wins the immediate request boundary regardless of autocmd registration order.
  vim.schedule(function()
    fire.fire(EVENT_NAME, payload)
  end)
end

function M.record_output(chat, tool, for_llm, for_user)
  local batch = chat and chat[BATCH_FIELD]
  if batch then
    local result_msg = find_result_message(chat, tool)
    merge_output_into_batch(batch, normalize_tool_output(tool, for_llm, for_user, result_msg))
  end
end

local function setup_tools_finished_autocmd()
  local group = vim.api.nvim_create_augroup("MaxaAbilityHookToolCallsCompleted", { clear = true })
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "MaxaAIToolsFinished",
    callback = function(args)
      local data = args.data or {}
      local chat = get_chat_from_bufnr(data.bufnr)
      local batch = chat and chat[BATCH_FIELD]
      if not chat or not batch then
        return
      end

      chat[BATCH_FIELD] = nil
      if data.cancelled == true then
        return
      end
      fire_completed(chat, batch, data)
    end,
  })
end

function M.start_batch(chat, tools)
  if not chat then
    return
  end

  chat[SEQ_FIELD] = (chat[SEQ_FIELD] or 0) + 1
  chat[BATCH_FIELD] = {
    local_batch_id = chat[SEQ_FIELD],
    requested_calls = snapshot_calls(tools or {}),
    outputs_by_key = {},
    outputs_order = {},
    started_at_ms = now_ms(),
  }
end

function M.setup()
  if setup_done then
    return
  end
  setup_done = true

  setup_tools_finished_autocmd()
end

function M.reset_setup()
  setup_done = false
end

return M
