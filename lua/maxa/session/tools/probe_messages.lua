-- preview_compact_range: 多点探测当前会话的消息位置
-- 支持传入多个探测点，返回每个探测点的上下文预览
-- 兼容扩展：可选返回结构分区与 context_status，供压缩 agent 制定策略

local history_core = require("maxa.session.history_core")
local history_session = require("maxa.session.history_session")
local compaction_messages = require("maxa.session.compaction_messages")
local param_utils = require("maxa.mcphub.native_servers.shared.params")
local session_status = require("maxa.session.session_status")

-- 预览字数配置
local PREVIEW_LEN_CURRENT = 500 -- 当前消息预览长度
local PREVIEW_LEN_ADJACENT = 200 -- 上下消息预览长度
local PARTITION_PREVIEW_LEN = 280 -- 分区预览长度

local WARMUP_USER_CONTENT = "不要思考，直接回复`ok`，不要有任何多余字符。"
local WARMUP_TAGS = {
  default_session_cache_warmup = true,
  default_session_cache_warmup_response = true,
  default_session_cache_warmup_tool_result = true,
}
local CONTEXT_TAGS = {
  rules = true,
  context_file = true,
  ability_revision = true,
  ability_instructions = true,
  ability_guidance = true,
  ability_catalog = true,
  ability_reference = true,
  ability_hook = true,
  ability_hook_tombstone = true,
}
-- Retired Skill/MCP tags are historical evidence only. They are intentionally
-- not promoted into the current runtime's protected Ability context.
local LOAD_CONTEXT_TOOLS = {
  load = true,
}

local function normalize_role(role)
  if role == "llm" then
    return "assistant"
  end
  return role or "unknown"
end

local function get_meta(msg)
  if type(msg) ~= "table" then
    return {}
  end
  return msg._meta or (msg.opts and msg.opts._meta) or {}
end

local function get_meta_tag(msg)
  local meta = get_meta(msg)
  return meta.tag
end

local function trim_lower(value)
  if type(value) ~= "string" then
    return ""
  end
  return vim.trim(value):lower()
end

local function safe_json_bytes(value)
  local ok, encoded = pcall(vim.json.encode, value or {})
  if ok and type(encoded) == "string" then
    return #encoded
  end
  if type(value) == "table" and type(value.content) == "string" then
    return #value.content
  end
  return 0
end

local function compact_text(value, max_len)
  if type(value) ~= "string" or value == "" then
    return ""
  end
  local text = value:gsub("%s+", " ")
  text = vim.trim(text)
  if #text > max_len then
    return text:sub(1, max_len - 3) .. "..."
  end
  return text
end

local function tool_call_id(msg)
  return msg and ((msg.tools and msg.tools.call_id) or msg.tool_call_id) or nil
end

local function iter_tool_calls(msg)
  local calls = {}
  if type(msg) ~= "table" then
    return calls
  end
  if msg.tools and type(msg.tools.calls) == "table" then
    for _, call in ipairs(msg.tools.calls) do
      table.insert(calls, call)
    end
  end
  if type(msg.tool_calls) == "table" then
    for _, call in ipairs(msg.tool_calls) do
      table.insert(calls, call)
    end
  end
  return calls
end

local function tool_name_from_call(call)
  if type(call) ~= "table" then
    return nil
  end
  local fn = call["function"]
  if type(fn) == "table" and type(fn.name) == "string" then
    return fn.name
  end
  if type(call.name) == "string" then
    return call.name
  end
  return nil
end

local function build_context_call_id_set(messages)
  local ids = {}
  for _, msg in ipairs(messages or {}) do
    for _, call in ipairs(iter_tool_calls(msg)) do
      local name = tool_name_from_call(call)
      local id = call.call_id or call.id
      if id and LOAD_CONTEXT_TOOLS[name] then
        ids[id] = true
      end
    end
  end
  return ids
end

local function has_context_tool_call(msg)
  for _, call in ipairs(iter_tool_calls(msg)) do
    local name = tool_name_from_call(call)
    if LOAD_CONTEXT_TOOLS[name] then
      return true
    end
  end
  return false
end

local function is_context_related_message(msg, context_call_ids)
  if type(msg) ~= "table" then
    return false
  end
  local tag = get_meta_tag(msg)
  if CONTEXT_TAGS[tag] then
    return true
  end
  if msg.context and msg.context.id then
    return true
  end
  if has_context_tool_call(msg) then
    return true
  end
  local call_id = tool_call_id(msg)
  if call_id and context_call_ids and context_call_ids[call_id] then
    return true
  end
  return false
end

local function is_initial_prefix_message(msg, context_call_ids)
  local role = normalize_role(msg and msg.role)
  local tag = get_meta_tag(msg)
  if role == "system" then
    return true
  end
  if tag == "system_prompt_from_config" or tag == "rules" or tag == "agent_boundary" then
    return true
  end
  if is_context_related_message(msg, context_call_ids) then
    return true
  end
  return false
end

local function is_warmup_message(msg)
  local tag = get_meta_tag(msg)
  if WARMUP_TAGS[tag] then
    return true
  end
  if normalize_role(msg and msg.role) == "user" and type(msg.content) == "string" then
    return vim.trim(msg.content) == WARMUP_USER_CONTENT
  end
  return false
end

local function is_warmup_ok_response(msg)
  if WARMUP_TAGS[get_meta_tag(msg)] then
    return true
  end
  return normalize_role(msg and msg.role) == "assistant" and trim_lower(msg.content) == "ok"
end

local function detect_warmup_range(messages, start_index)
  local first = messages[start_index]
  if not is_warmup_message(first) then
    return nil
  end

  local end_index = start_index
  local saw_ok = false
  local limit = math.min(#messages, start_index + 5)
  for i = start_index + 1, limit do
    local msg = messages[i]
    if WARMUP_TAGS[get_meta_tag(msg)] then
      end_index = i
      if is_warmup_ok_response(msg) then
        saw_ok = true
      end
    elseif is_warmup_ok_response(msg) then
      end_index = i
      saw_ok = true
      break
    elseif normalize_role(msg and msg.role) == "tool" and WARMUP_TAGS[get_meta_tag(msg)] then
      end_index = i
    else
      break
    end
  end

  return end_index, saw_ok
end

local function is_plain_user_message(msg)
  if type(msg) ~= "table" then
    return false
  end
  if normalize_role(msg.role) ~= "user" then
    return false
  end
  if msg.context then
    return false
  end
  if get_meta_tag(msg) then
    return false
  end
  return type(msg.content) == "string" and vim.trim(msg.content) ~= ""
end

local function find_active_tail_start(messages, min_start)
  for i = #messages, math.max(min_start or 1, 1), -1 do
    if is_plain_user_message(messages[i]) then
      return i
    end
  end
  if #messages >= (min_start or 1) then
    return #messages
  end
  return nil
end

local function collect_partition_stats(messages, start_index, end_index, kind, flags)
  local bytes = 0
  local roles = {}
  local meta_tags = {}
  local tool_name_set = {}
  local tool_names = {}
  local context_count = 0
  local preview_parts = {}
  local preview_bytes = 0

  for i = start_index, end_index do
    local msg = messages[i]
    if msg then
      bytes = bytes + safe_json_bytes(msg)

      local role = normalize_role(msg.role)
      roles[role] = (roles[role] or 0) + 1

      local tag = get_meta_tag(msg)
      if tag then
        meta_tags[tag] = (meta_tags[tag] or 0) + 1
      end

      if msg.context and msg.context.id then
        context_count = context_count + 1
      end

      for _, call in ipairs(iter_tool_calls(msg)) do
        local name = tool_name_from_call(call)
        if name and not tool_name_set[name] then
          tool_name_set[name] = true
          table.insert(tool_names, name)
        end
      end

      if #preview_parts < 4 then
        local content = compact_text(msg.content, 90)
        if content ~= "" then
          local piece = string.format("[%d:%s] %s", i, role, content)
          preview_bytes = preview_bytes + #piece
          if preview_bytes <= PARTITION_PREVIEW_LEN then
            table.insert(preview_parts, piece)
          end
        end
      end
    end
  end

  table.sort(tool_names)

  return {
    start_index = start_index,
    end_index = end_index,
    start_offset = start_index - 1,
    end_offset = end_index - 1,
    message_count = end_index - start_index + 1,
    bytes = bytes,
    kind = kind,
    flags = flags or {},
    roles = roles,
    meta_tags = meta_tags,
    tool_names = tool_names,
    context_count = context_count,
    preview = table.concat(preview_parts, " | "),
  }
end

local function finalize_partitions(partitions)
  local total_bytes = 0
  for _, part in ipairs(partitions) do
    total_bytes = total_bytes + (part.bytes or 0)
  end
  for idx, part in ipairs(partitions) do
    part.id = idx - 1
    if total_bytes > 0 then
      part.bytes_percent = math.floor(((part.bytes or 0) / total_bytes) * 1000 + 0.5) / 10
    else
      part.bytes_percent = 0
    end
  end
  return partitions, total_bytes
end

local function analyze_partitions(messages, source)
  messages = messages or {}
  if #messages == 0 then
    return {
      total_partition_bytes = 0,
      partitions = {},
    }
  end

  local context_call_ids = build_context_call_id_set(messages)
  local protected_count = compaction_messages.get_protected_prefix_count(source)
  if protected_count > #messages then
    protected_count = #messages
  end

  local partitions = {}
  local cursor = 1

  local initial_end = 0
  local initial_flags = { "initial_partition" }
  if protected_count > 0 then
    initial_end = protected_count
    table.insert(initial_flags, "protected_prefix")
  else
    while initial_end + 1 <= #messages and is_initial_prefix_message(messages[initial_end + 1], context_call_ids) do
      initial_end = initial_end + 1
    end
    if initial_end == 0 then
      initial_end = 1
    end
  end

  table.insert(partitions, collect_partition_stats(messages, 1, initial_end, "initial_prefix", initial_flags))
  cursor = initial_end + 1

  if cursor <= #messages then
    local warmup_end, saw_ok = detect_warmup_range(messages, cursor)
    if warmup_end then
      local flags = { "warmup" }
      if saw_ok then
        table.insert(flags, "warmup_ok")
      end
      table.insert(partitions, collect_partition_stats(messages, cursor, warmup_end, "warmup", flags))
      cursor = warmup_end + 1
    end
  end

  local active_tail_start = find_active_tail_start(messages, cursor)
  if active_tail_start and active_tail_start <= cursor then
    active_tail_start = nil
  end
  local middle_end = active_tail_start and (active_tail_start - 1) or #messages

  while cursor <= middle_end do
    if is_context_related_message(messages[cursor], context_call_ids) then
      local end_index = cursor
      while end_index + 1 <= middle_end and is_context_related_message(messages[end_index + 1], context_call_ids) do
        end_index = end_index + 1
      end
      table.insert(partitions, collect_partition_stats(messages, cursor, end_index, "context_burst", { "context_related" }))
      cursor = end_index + 1
    else
      local end_index = cursor
      local user_turns = is_plain_user_message(messages[cursor]) and 1 or 0
      while end_index + 1 <= middle_end do
        local next_msg = messages[end_index + 1]
        if is_context_related_message(next_msg, context_call_ids) then
          break
        end
        if is_plain_user_message(next_msg) then
          if user_turns >= 4 then
            break
          end
          user_turns = user_turns + 1
        end
        end_index = end_index + 1
      end
      table.insert(partitions, collect_partition_stats(messages, cursor, end_index, "conversation", {}))
      cursor = end_index + 1
    end
  end

  if active_tail_start and active_tail_start <= #messages then
    table.insert(partitions, collect_partition_stats(messages, active_tail_start, #messages, "active_tail", { "active_tail" }))
  elseif #partitions > 1 then
    local last = partitions[#partitions]
    last.kind = "active_tail"
    last.flags = last.flags or {}
    table.insert(last.flags, "active_tail")
  elseif #partitions == 1 then
    -- 单分区会话中唯一分区同时是首分区和尾部分区；保留 initial_prefix kind，追加 active_tail flag。
    local last = partitions[1]
    last.flags = last.flags or {}
    table.insert(last.flags, "active_tail")
  end

  local _, total_bytes = finalize_partitions(partitions)
  return {
    protected_prefix_count = protected_count,
    total_partition_bytes = total_bytes,
    partitions = partitions,
  }
end

local function build_context_status(source, save_id)
  local status
  if source and source.chat then
    status = session_status.from_chat(source.chat)
  elseif source and source.chat_data then
    status = session_status.from_chat_data(source.chat_data, save_id)
  else
    status = session_status.from_messages(source and source.messages or {}, { save_id = save_id })
  end
  return session_status.to_llm(status)
end

--- 在消息列表中搜索匹配 marker 的消息（搜索所有消息，不做角色过滤）
---@param messages table[] 消息列表
---@param marker string 搜索关键词
---@param role string|nil 消息角色过滤 ("user" | "assistant" | "system" | "tool")
---@param occurrence number 匹配第几次出现 (1-based)
---@return number|nil index 匹配的消息索引
---@return table|nil message 匹配的消息对象
local function find_message_by_marker(messages, marker, role, occurrence)
  local count = 0
  for i, msg in ipairs(messages) do
    -- 角色过滤（仅当指定了 role 参数时）
    local msg_role = normalize_role(msg.role)
    if role and msg_role ~= role then
      goto continue
    end

    -- 内容匹配（搜索 content）
    local content = msg.content or ""
    if content:find(marker, 1, true) then
      count = count + 1
      if count == occurrence then
        return i, msg
      end
    end

    ::continue::
  end
  return nil, nil
end

--- 生成消息预览
---@param msg table|nil 消息对象
---@param index number|nil 消息索引
---@param max_len number 最大长度
---@return table|nil preview 预览对象
local function create_message_preview(msg, index, max_len)
  if not msg or not index then
    return nil
  end

  local role = normalize_role(msg.role)
  local content = msg.content or ""
  local content_len = #content
  local truncated = false

  if content_len > max_len then
    content = content:sub(1, max_len) .. "..."
    truncated = true
  end

  return {
    index = index,
    role = role,
    content = content,
    content_len = content_len,
    truncated = truncated,
  }
end

--- 查找相邻消息（不做过滤，返回真正的前后消息）
---@param messages table[] 消息列表
---@param current_index number 当前索引
---@param direction number 方向 (-1 向前, 1 向后)
---@return number|nil index 相邻消息索引
---@return table|nil message 相邻消息对象
local function find_adjacent_message(messages, current_index, direction)
  local i = current_index + direction
  if i >= 1 and i <= #messages then
    return i, messages[i]
  end
  return nil, nil
end

--- 处理单个探测点
---@param messages table[] 消息列表
---@param probe table 探测点配置 {marker, role, occurrence}
---@return table result 探测结果
local function process_probe(messages, probe)
  local marker = probe.marker
  local role = probe.role
  local occurrence = probe.occurrence or 1

  -- 参数验证
  if not marker or marker == "" then
    return {
      success = false,
      error = "marker is required",
    }
  end

  -- 搜索消息
  local index, msg = find_message_by_marker(messages, marker, role, occurrence)
  if not index then
    return {
      success = false,
      error = string.format("marker not found (marker=%q, role=%s, occurrence=%d)", marker, role or "any", occurrence),
      search = {
        marker = marker,
        role = role,
        occurrence = occurrence,
      },
    }
  end

  -- 查找相邻消息
  local prev_index, prev_msg = find_adjacent_message(messages, index, -1)
  local next_index, next_msg = find_adjacent_message(messages, index, 1)

  -- 生成预览
  return {
    success = true,
    search = {
      marker = marker,
      role = role,
      occurrence = occurrence,
    },
    current = create_message_preview(msg, index, PREVIEW_LEN_CURRENT),
    previous = create_message_preview(prev_msg, prev_index, PREVIEW_LEN_ADJACENT),
    next = create_message_preview(next_msg, next_index, PREVIEW_LEN_ADJACENT),
  }
end

--- probe_messages 工具处理函数
---@param req table 请求对象
---@param res table 响应对象
local function probe_messages(req, res)
  local params = param_utils.normalize(req.params)
  local save_id = params.save_id
  local probes = params.probes
  local include_partitions = params.include_partitions == true
  local include_context_status = params.include_context_status == true

  -- 压缩会话 save_id 校验：仅当 caller chat 有 _compact_target_save_id 标记时触发
  local chat = req.caller and req.caller.maxa_ai and req.caller.maxa_ai.chat
  if chat and chat._compact_target_save_id then
    local expected = chat._compact_target_save_id
    if not save_id or save_id == "" then
      return res:error(string.format("probe_messages: save_id is required for compression. Use: '%s'", expected))
    end
    if save_id ~= expected then
      return res:error(
        string.format("probe_messages: Invalid save_id '%s'. Expected: '%s'", save_id, expected)
      )
    end
  end

  local has_probes = probes and type(probes) == "table" and #probes > 0
  if not has_probes and not include_partitions and not include_context_status then
    return res:error("probe_messages: probes array is required unless include_partitions or include_context_status is true")
  end

  if probes ~= nil and type(probes) ~= "table" then
    return res:error("probe_messages: probes must be an array when provided")
  end

  if has_probes and #probes > 10 then
    return res:error("probe_messages: too many probes (max 10)")
  end

  -- 获取消息列表
  local source, source_err = history_session.get_messages_source(save_id, req.caller)
  if not source then
    return res:error("probe_messages: " .. source_err)
  end

  local messages = source.messages or {}
  local source_type = source.source_type
  save_id = source.save_id or save_id
  local total_count = #messages

  -- 处理每个探测点
  local results = {}
  if has_probes then
    for i, probe in ipairs(probes) do
      results[i] = process_probe(messages, probe)
    end
  end

  -- 构建响应
  local response_data = {
    source = source_type,
    save_id = save_id,
    total_messages = total_count,
    probes = results,
  }

  if include_context_status then
    response_data.context_status = build_context_status(source, save_id)
  end

  if include_partitions then
    local partition_analysis = analyze_partitions(messages, source)
    response_data.partition_analysis = {
      protected_prefix_count = partition_analysis.protected_prefix_count,
      total_partition_bytes = partition_analysis.total_partition_bytes,
    }
    response_data.partitions = partition_analysis.partitions
  end

  return res:text(vim.json.encode(history_core.create_response(response_data))):send()
end

return {
  _test = {
    analyze_partitions = analyze_partitions,
    safe_json_bytes = safe_json_bytes,
  },

  name = "probe_messages",
  description = table.concat({
    "Locate messages by marker and optionally return structural partitions and context status for compaction planning.",
    "Use probes for current/previous/next previews with indices; use include_partitions/include_context_status before compact_range.",
    "Partitions are structural facts only, with 1-based start_index/end_index for compact_range and 0-based offsets for reasoning; they do not judge relevance.",
  }, " "),

  inputSchema = {
    type = "object",
    properties = {
      save_id = {
        type = "string",
        description = "Chat session ID. If not provided, reads from the current session.",
      },
      probes = {
        type = "array",
        description = "Probe points to search; optional when requesting only partitions or context status.",
        items = {
          type = "object",
          properties = {
            marker = {
              type = "string",
              description = "Unique keyword/phrase from the target message.",
            },
            role = {
              type = "string",
              enum = { "user", "assistant", "system", "tool" },
              description = "Optional role filter; omitted searches all conversation messages.",
            },
            occurrence = {
              type = "number",
              description = "Occurrence to match when marker repeats; default 1.",
            },
          },
          required = { "marker" },
        },
        minItems = 0,
        maxItems = 10,
      },
      include_partitions = {
        type = "boolean",
        description = "Return structural partitions with byte sizes/percentages for compaction planning.",
      },
      include_context_status = {
        type = "boolean",
        description = "Return context_status: token usage/limit/percent, messages JSON bytes, and message count.",
      },
    },
  },

  handler = probe_messages,
}
