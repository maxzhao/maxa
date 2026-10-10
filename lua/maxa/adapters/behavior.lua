-- Shared adapter behavior owned directly by canonical adapter implementations.
local M = {}

M.MAX_REASONING_TURNS = nil

local LEGACY_CAPABILITY_TAGS = {
  skill = true,
  mcp_server = true,
  mcp_docs = true,
  mcp_tools = true,
  mcp_resources = true,
  skill_hook = true,
  skill_hook_tombstone = true,
  auto_skill_dependency_call = true,
  auto_skill_dependency_result = true,
}

local function is_legacy_capability_context(message, tag)
  local context = message.context or {}
  local id = context.id
  if LEGACY_CAPABILITY_TAGS[tag] or context.skill_hook or context.skill_hook_once or context.skill_hook_once_paths then
    return true
  end
  if type(id) == "string" and (id:match("^skill:") or id:match("^mcp:")) then
    return true
  end
  if tag == "context_file" and type(id) == "string" then
    local retired_global = vim.fn.stdpath("config") .. "/skills/"
    if id:find("/.maxa/skills/", 1, true) or id:sub(1, #retired_global) == retired_global then
      return true
    end
  end
  return false
end

function M.strip_internal_messages(messages)
  for index = #messages, 1, -1 do
    local message = messages[index]
    local tag = message._meta and message._meta.tag
    if tag == "ability_hook_tombstone" or is_legacy_capability_context(message, tag) then
      table.remove(messages, index)
    elseif message._meta and message._meta._tool_summary_applied and message.tools and message.tools.calls then
      if type(message.content) == "string" then
        message.content = nil
      end
    end
  end
  return messages
end

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
    index = index + sequence_length
  end
  return true
end

local function ensure_utf8(value)
  if not value:find("[\128-\255]") or is_valid_utf8(value) then
    return value
  end
  for _, source_encoding in ipairs({ "gbk", "latin1" }) do
    local converted = vim.fn.iconv(value, source_encoding, "utf-8")
    if converted and converted ~= "" and is_valid_utf8(converted) then
      return converted
    end
  end
  return value
end

function M.deep_ensure_utf8(value)
  if type(value) == "string" then
    return ensure_utf8(value)
  end
  if type(value) == "table" then
    for key, nested in pairs(value) do
      value[key] = M.deep_ensure_utf8(nested)
    end
  end
  return value
end

function M.filter_reasoning(result, messages)
  local saved_reasoning = {}
  for index, message in ipairs(messages) do
    if message._meta and message._meta.reasoning_tainted and message.reasoning then
      saved_reasoning[index] = message.reasoning
      message.reasoning = nil
    end
  end
  return function(output)
    for index, reasoning in pairs(saved_reasoning) do
      messages[index].reasoning = reasoning
    end
    local max_turns = M.MAX_REASONING_TURNS
    if max_turns == nil or not (output and output.messages) then
      return output
    end
    if max_turns == 0 then
      for _, message in ipairs(output.messages) do
        message.reasoning = nil
      end
      return output
    end
    local user_count, cutoff = 0, nil
    for index = #output.messages, 1, -1 do
      if output.messages[index].role == "user" then
        user_count = user_count + 1
        if user_count >= max_turns then
          cutoff = index
          break
        end
      end
    end
    if cutoff then
      for index = 1, cutoff - 1 do
        output.messages[index].reasoning = nil
      end
    end
    return output
  end
end

local function positive_number(value)
  local number = tonumber(value)
  return number and number >= 0 and number or nil
end

function M.decode(data)
  if type(data) == "table" then
    if not data.body then return data end
    data = data.body
  end
  if type(data) ~= "string" or data == "" then return nil end
  local adapter_utils = require("maxa.utils.adapters")
  local ok, json = pcall(vim.json.decode, adapter_utils.clean_streamed_data(data), { luanil = { object = true } })
  return ok and type(json) == "table" and json or nil
end

function M.usage(data)
  local json = M.decode(data)
  if not json then return nil end
  local usage = json.usage
  if (json.type == "response.completed" or json.type == "response.incomplete") and json.response and json.response.usage then
    usage = json.response.usage
  elseif json.type == "message_start" and json.message then
    usage = json.message.usage
  end
  if not usage then
    return nil
  end
  local result = {
    total_tokens = positive_number(usage.total_tokens),
    input_tokens = positive_number(usage.input_tokens or usage.prompt_tokens),
    output_tokens = positive_number(usage.output_tokens or usage.completion_tokens),
    cache_metric_supported = false,
  }
  local cached_tokens = type(usage.prompt_tokens_details) == "table"
      and positive_number(usage.prompt_tokens_details.cached_tokens)
    or nil
  if type(usage.input_tokens_details) == "table" then
    cached_tokens = cached_tokens or positive_number(usage.input_tokens_details.cached_tokens)
  end
  local cache_read = positive_number(usage.cache_read_input_tokens)
  local cache_creation = positive_number(usage.cache_creation_input_tokens)
  if cached_tokens ~= nil or cache_read ~= nil or cache_creation ~= nil then
    result.cache_metric_supported = true
    result.cached_tokens = cached_tokens
    result.cache_read_input_tokens = cache_read
    result.cache_creation_input_tokens = cache_creation
  end
  return result
end

function M.output_bytes(...)
  local bytes = 0
  for index = 1, select("#", ...) do
    local value = select(index, ...)
    if type(value) == "string" then bytes = bytes + #value end
  end
  return bytes
end

function M.reset_usage(adapter)
  adapter._total_tokens = nil
  adapter._last_usage = nil
end

function M.record_usage(adapter, data)
  local usage = M.usage(data)
  if usage then
    usage.total_tokens = usage.total_tokens or ((usage.input_tokens or 0) + (usage.output_tokens or 0))
    adapter._total_tokens = usage.total_tokens
    adapter._last_usage = usage
  end
  return usage
end

function M.sort_tools(tools)
  table.sort(tools or {}, function(left, right)
    local left_function, right_function = left["function"] or {}, right["function"] or {}
    local left_name = left.name or left_function.name or ""
    local right_name = right.name or right_function.name or ""
    if left_name == right_name then
      return tostring(left.type or "") < tostring(right.type or "")
    end
    return left_name < right_name
  end)
end

return M
