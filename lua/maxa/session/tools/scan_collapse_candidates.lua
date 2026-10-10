-- scan_collapse_candidates: 扫描 collapse_tail 范围内的结构化保留候选
-- 不读取/返回原文 snippet，不调用 LLM；只返回 index 与消息元数据供 Mini Agent 判断 preserve_indices

local history_core = require("maxa.session.history_core")
local history_session = require("maxa.session.history_session")
local compaction_messages = require("maxa.session.compaction_messages")
local wrapped_calls = require("maxa.interactions.chat.tools.builtin.runtime.wrapped_tool_calls")
local param_utils = require("maxa.mcphub.native_servers.shared.params")

local M = {}

local function make_error(message, extra)
  local payload = vim.tbl_extend("force", {
    status = "error",
    error_type = "scan_collapse_candidates_validation_error",
    message = message,
    retryable = true,
  }, extra or {})
  return vim.json.encode(payload)
end

local function normalize_index(value)
  local n = tonumber(value)
  if not n then
    return nil
  end
  return math.floor(n)
end

local function normalize_role(role)
  return role == "llm" and "assistant" or role
end

local function get_meta(msg)
  return msg._meta or (msg.opts and msg.opts._meta) or {}
end

local function estimate_bytes(msg)
  local total = 0
  if type(msg.content) == "string" then
    total = total + #msg.content
  end
  if msg.context and msg.context.id then
    total = total + #tostring(msg.context.id)
  end
  local meta = get_meta(msg)
  if meta.tag then
    total = total + #tostring(meta.tag)
  end
  return total
end

local function line_count(content)
  if type(content) ~= "string" or content == "" then
    return 0
  end
  local _, count = content:gsub("\n", "")
  return count + 1
end

local function extract_loaded_value(tool_name, arguments)
  local args = type(arguments) == "table" and arguments or nil
  if not args and type(arguments) == "string" and arguments ~= "" then
    local ok, parsed = pcall(vim.json.decode, arguments)
    if ok and type(parsed) == "table" then
      args = parsed
    end
  end
  if not args then
    return nil, nil
  end

  if tool_name == "load" then
    return "load", args.target
  end
  return nil, nil
end

local function append_count(counts, key)
  counts[key] = (counts[key] or 0) + 1
end

local function get_tool_calls(msg)
  if msg.tools and msg.tools.calls then
    return msg.tools.calls
  end
  if msg.tool_calls then
    return msg.tool_calls
  end
  return nil
end

local function get_call_id(call)
  return call.call_id or call.id
end

local function get_call_function(call)
  local func = call["function"] or {}
  return func.name or call.name, func.arguments or call.arguments
end

local function get_tool_result_call_id(msg)
  return (msg.tools and msg.tools.call_id) or msg.tool_call_id
end

local function classify_context_message(msg)
  local meta = get_meta(msg)
  local tag = meta.tag
  local context_id = msg.context and msg.context.id or nil
  if tag == "ability_revision" or tag == "ability_instructions" or tag == "ability_guidance" then
    local ability = meta.ability
    return "load", ability and ability.name or (context_id and context_id:match("^ability:[^:]+:(.+)$"))
  elseif tag == "context_file" then
    return "context", context_id
  end
  return nil, nil
end

local function sorted_values(map)
  local values = {}
  for _, value in pairs(map) do
    table.insert(values, value)
  end
  table.sort(values, function(a, b)
    local ai = a.index or a.call_index or a.result_index or 0
    local bi = b.index or b.call_index or b.result_index or 0
    if ai == bi then
      return tostring(a.value or a.tool_name or a.context_id or "") < tostring(b.value or b.tool_name or b.context_id or "")
    end
    return ai < bi
  end)
  return values
end

--- Build structured facts for messages inside collapse_start_index..last.
--- Returned data intentionally excludes original content snippets and judgement reasons.
---@param messages table[] original messages
---@param collapse_start_index number 1-based start index
---@return table|nil data
---@return string|nil err
function M.build_candidates(messages, collapse_start_index)
  if type(messages) ~= "table" or #messages == 0 then
    return nil, "messages must be a non-empty array"
  end

  collapse_start_index = normalize_index(collapse_start_index)
  if not collapse_start_index then
    return nil, "collapse_start_index is required and must be a number"
  end

  local total_count = #messages
  if collapse_start_index < 1 or collapse_start_index >= total_count then
    return nil,
      string.format(
        "collapse_start_index must be >= 1 and < last message index (%d); got %d",
        total_count,
        collapse_start_index
      )
  end

  local call_info = {}
  local loaded_call_infos = {}
  local tool_result_info = {}

  -- First pass over all messages so tool call/result status remains available even when
  -- one side of the pair is just outside the collapse range.
  for index, msg in ipairs(messages) do
    local calls = get_tool_calls(msg)
    if calls then
      for _, call in ipairs(calls) do
        local call_id = get_call_id(call)
        local tool_name, arguments = get_call_function(call)
        if call_id then
          local direct_item_type, direct_value = extract_loaded_value(tool_name, arguments)
          call_info[call_id] = {
            call_id = call_id,
            tool_name = tool_name,
            call_index = index,
            item_type = direct_item_type,
            value = direct_value,
          }

          for _, semantic in ipairs(wrapped_calls.expand_call(call)) do
            local item_type, value = wrapped_calls.loaded_value(semantic.tool_name, semantic.args)
            if item_type and value then
              loaded_call_infos[call_id] = loaded_call_infos[call_id] or {}
              table.insert(loaded_call_infos[call_id], {
                call_id = call_id,
                tool_name = semantic.tool_name,
                call_index = index,
                item_type = item_type,
                value = value,
              })
            end
          end
        end
      end
    elseif msg.role == "tool" then
      local call_id = get_tool_result_call_id(msg)
      if call_id then
        tool_result_info[call_id] = {
          call_id = call_id,
          result_index = index,
          status = history_core.is_tool_error(msg) and "error" or "success",
          bytes = estimate_bytes(msg),
        }
      end
    end
  end

  local counts = {
    total = 0,
    system = 0,
    user = 0,
    assistant = 0,
    tool = 0,
    tagged = 0,
    context = 0,
    tool_call_messages = 0,
    tool_result_messages = 0,
  }

  local loaded_items_by_key = {}
  local tagged_messages = {}
  local tool_call_messages = {}
  local tool_result_messages = {}
  local conversation_messages = {}
  local system_messages = {}
  local context_messages = {}

  for index = collapse_start_index, total_count do
    local msg = messages[index]
    local role = normalize_role(msg.role)
    append_count(counts, "total")
    append_count(counts, role or "unknown")

    local meta = get_meta(msg)
    local bytes = estimate_bytes(msg)
    local base = {
      index = index,
      role = role,
      bytes = bytes,
      line_count = line_count(msg.content),
    }

    if meta.tag then
      append_count(counts, "tagged")
      local tagged = vim.tbl_extend("force", base, {
        tag = meta.tag,
        context_id = msg.context and msg.context.id or nil,
      })
      table.insert(tagged_messages, tagged)
    end

    if msg.context and msg.context.id then
      append_count(counts, "context")
      local item_type, value = classify_context_message(msg)
      local context_entry = vim.tbl_extend("force", base, {
        tag = meta.tag,
        context_id = msg.context.id,
        item_type = item_type,
        value = value,
      })
      table.insert(context_messages, context_entry)

      if item_type and value then
        local key = item_type .. ":" .. value
        local entry = loaded_items_by_key[key] or {
          item_type = item_type,
          value = value,
          context_indices = {},
          call_indices = {},
          result_indices = {},
          bytes = 0,
        }
        table.insert(entry.context_indices, index)
        entry.bytes = entry.bytes + bytes
        loaded_items_by_key[key] = entry
      end
    end

    local calls = get_tool_calls(msg)
    if calls then
      append_count(counts, "tool_call_messages")
      local tools = {}
      for _, call in ipairs(calls) do
        local call_id = get_call_id(call)
        local tool_name, arguments = get_call_function(call)
        local item_type, value = extract_loaded_value(tool_name, arguments)
        local result = call_id and tool_result_info[call_id] or nil
        table.insert(tools, {
          call_id = call_id,
          tool_name = tool_name,
          status = result and result.status or "missing_result",
          result_index = result and result.result_index or nil,
          item_type = item_type,
          value = value,
        })

        for _, loaded_info in ipairs((call_id and loaded_call_infos[call_id]) or {}) do
          local key = loaded_info.item_type .. ":" .. loaded_info.value
          local entry = loaded_items_by_key[key] or {
            item_type = loaded_info.item_type,
            value = loaded_info.value,
            context_indices = {},
            call_indices = {},
            result_indices = {},
            bytes = 0,
          }
          table.insert(entry.call_indices, index)
          if result and result.result_index then
            table.insert(entry.result_indices, result.result_index)
          end
          loaded_items_by_key[key] = entry
        end
      end
      table.insert(tool_call_messages, vim.tbl_extend("force", base, { tools = tools }))
    elseif msg.role == "tool" then
      append_count(counts, "tool_result_messages")
      local call_id = get_tool_result_call_id(msg)
      local info = call_id and call_info[call_id] or nil
      table.insert(tool_result_messages, vim.tbl_extend("force", base, {
        call_id = call_id,
        status = history_core.is_tool_error(msg) and "error" or "success",
        tool_name = info and info.tool_name or nil,
        call_index = info and info.call_index or nil,
        item_type = info and info.item_type or nil,
        value = info and info.value or nil,
      }))
    elseif role == "user" or role == "assistant" then
      table.insert(conversation_messages, vim.tbl_extend("force", base, {
        has_context = msg.context ~= nil,
        tag = meta.tag,
      }))
    elseif role == "system" then
      table.insert(system_messages, vim.tbl_extend("force", base, {
        tag = meta.tag,
      }))
    end
  end

  local loaded_items = sorted_values(loaded_items_by_key)
  table.sort(tagged_messages, function(a, b) return a.index < b.index end)
  table.sort(context_messages, function(a, b) return a.index < b.index end)
  table.sort(tool_call_messages, function(a, b) return a.index < b.index end)
  table.sort(tool_result_messages, function(a, b) return a.index < b.index end)
  table.sort(conversation_messages, function(a, b) return a.index < b.index end)
  table.sort(system_messages, function(a, b) return a.index < b.index end)

  return {
    range = {
      collapse_start_index = collapse_start_index,
      collapse_end_index = total_count,
      total_messages = total_count,
    },
    counts = counts,
    candidates = {
      loaded_items = loaded_items,
      context_messages = context_messages,
      tagged_messages = tagged_messages,
      tool_call_messages = tool_call_messages,
      tool_result_messages = tool_result_messages,
      conversation_messages = conversation_messages,
      system_messages = system_messages,
    },
  }, nil
end

local function scan_collapse_candidates(req, res)
  local params = param_utils.normalize(req.params)
  local save_id = params.save_id
  if not save_id or save_id == "" then
    return res:error(make_error("scan_collapse_candidates: save_id is required", { suggested_action = "provide_save_id" })):send()
  end

  local caller_chat = req.caller and req.caller.maxa_ai and req.caller.maxa_ai.chat
  if caller_chat and caller_chat._compact_target_save_id then
    local expected = caller_chat._compact_target_save_id
    if save_id ~= expected then
      return res
        :error(
          make_error(
            string.format("scan_collapse_candidates: Invalid save_id '%s'. Expected: '%s'", save_id, expected),
            { expected_save_id = expected, actual_save_id = save_id, suggested_action = "use_expected_save_id" }
          )
        )
        :send()
    end
  end

  local source, source_err = history_session.get_messages_source(save_id, req.caller)
  if not source then
    return res:error(make_error("scan_collapse_candidates: " .. source_err, { suggested_action = "fix_session_source" })):send()
  end

  local protected_err = compaction_messages.validate_collapse_against_protected_prefix(
    normalize_index(params.collapse_start_index),
    compaction_messages.get_protected_prefix_count(source),
    "scan_collapse_candidates"
  )
  if protected_err then
    return res:error(vim.json.encode(protected_err)):send()
  end

  local data, build_err = M.build_candidates(source.messages or {}, params.collapse_start_index)
  if build_err then
    return res:error(make_error("scan_collapse_candidates: " .. build_err, { suggested_action = "reprobe_or_fix_collapse_start_index" })):send()
  end

  data.source = source.source_type
  data.save_id = source.save_id or save_id

  return res:text(vim.json.encode(history_core.create_response(data))):send()
end

M.handler = scan_collapse_candidates
M.name = "scan_collapse_candidates"
M.description = table.concat({
  "Scan the collapse_tail range and return structured candidate message facts for preserve_indices selection.",
  "This tool does not call an LLM and does not return message content snippets or judgement reasons.",
  "Use after locating collapse_start_index and before calling collapse_tail.",
}, " ")
M.inputSchema = {
  type = "object",
  properties = {
    save_id = {
      type = "string",
      description = "Chat session ID. Must match the target session.",
    },
    collapse_start_index = {
      type = "number",
      description = "1-based start index of the contiguous tail range to scan. Same range semantics as collapse_tail.",
    },
  },
  required = { "save_id", "collapse_start_index" },
}

return M
