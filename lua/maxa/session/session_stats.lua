local session_status = require("maxa.session.session_status")

local M = {}

local TOKEN_BYTES_RATIO = 2.5

local function safe_json(value)
  local ok, encoded = pcall(vim.json.encode, value or {})
  if ok and type(encoded) == "string" then
    return encoded
  end
  return ""
end

local function byte_len(value)
  if type(value) == "string" then
    return #value
  end
  return #safe_json(value)
end

local function estimate_tokens(bytes)
  if type(bytes) ~= "number" or bytes <= 0 then
    return 0
  end
  return math.floor(bytes / TOKEN_BYTES_RATIO + 0.5)
end

local function add_count(tbl, key, n)
  key = key or "unknown"
  tbl[key] = (tbl[key] or 0) + (n or 1)
end

local function has_tool_calls(msg)
  return type(msg) == "table"
    and ((type(msg.tool_calls) == "table" and #msg.tool_calls > 0)
      or (type(msg.tools) == "table" and type(msg.tools.calls) == "table" and #msg.tools.calls > 0))
end

local function normalize_tool_name(name)
  if type(name) ~= "string" or name == "" then
    return "unknown"
  end
  return name
end

local function get_tool_call_id(msg)
  if type(msg) ~= "table" then
    return nil
  end
  if type(msg.tool_call_id) == "string" then
    return msg.tool_call_id
  end
  if type(msg.tools) == "table" then
    return msg.tools.call_id or msg.tools.id
  end
  return nil
end

local function iter_tool_calls(msg)
  local calls = {}
  if type(msg) ~= "table" then
    return calls
  end

  if type(msg.tool_calls) == "table" then
    for _, call in ipairs(msg.tool_calls) do
      local fn = type(call) == "table" and call["function"] or nil
      table.insert(calls, {
        id = type(call) == "table" and (call.call_id or call.id) or nil,
        name = normalize_tool_name(type(fn) == "table" and fn.name or call.name),
        arguments = type(fn) == "table" and fn.arguments or call.arguments,
      })
    end
  end

  if type(msg.tools) == "table" and type(msg.tools.calls) == "table" then
    for _, call in ipairs(msg.tools.calls) do
      local fn = type(call) == "table" and call["function"] or nil
      table.insert(calls, {
        id = call.call_id or call.id,
        name = normalize_tool_name((type(fn) == "table" and fn.name) or call.name or call.tool),
        arguments = (type(fn) == "table" and fn.arguments) or call.arguments or call.args or call.params,
      })
    end
  end

  return calls
end

local function decode_arguments(args)
  if type(args) == "table" then
    return args
  end
  if type(args) == "string" and args ~= "" then
    local ok, decoded = pcall(vim.json.decode, args)
    if ok and type(decoded) == "table" then
      return decoded
    end
  end
  return nil
end

local function is_failure_tool_result(msg)
  local content = type(msg.content) == "string" and msg.content or safe_json(msg.content)
  local lowered = content:lower()
  if lowered:find("failed with the following error", 1, true) or lowered:find('"ok":false', 1, true) then
    return true
  end
  if lowered:find("status: failed", 1, true) or lowered:find("tool .* returned error") then
    return true
  end
  return false
end

local function ensure_tool_stat(stats, name)
  name = normalize_tool_name(name)
  stats[name] = stats[name] or {
    name = name,
    calls = 0,
    success = 0,
    failed = 0,
    input_bytes = 0,
    input_tokens = 0,
    output_bytes = 0,
    output_tokens = 0,
    latest_index = nil,
    duration_ms = 0,
    avg_duration_ms = 0,
    max_duration_ms = 0,
    latest_duration_ms = nil,
    timed_results = 0,
    ttl_notices = 0,
    discarded = 0,
    oversized = 0,
  }
  return stats[name]
end

local function add_tool_input(stats, name, input_bytes, index)
  local stat = ensure_tool_stat(stats, name)
  stat.calls = stat.calls + 1
  stat.input_bytes = stat.input_bytes + input_bytes
  stat.input_tokens = stat.input_tokens + estimate_tokens(input_bytes)
  stat.latest_index = index
  return stat
end

local function add_tool_output(stat, msg)
  local output_bytes = msg._meta and type(msg._meta.output_bytes) == "number" and msg._meta.output_bytes or byte_len(msg.content)
  stat.output_bytes = stat.output_bytes + output_bytes
  stat.output_tokens = stat.output_tokens + estimate_tokens(output_bytes)
  stat.latest_index = stat.latest_index or nil

  local duration_ms = msg._meta and type(msg._meta.duration_ms) == "number" and msg._meta.duration_ms or nil
  if duration_ms then
    stat.duration_ms = stat.duration_ms + duration_ms
    stat.timed_results = stat.timed_results + 1
    stat.latest_duration_ms = duration_ms
    if duration_ms > stat.max_duration_ms then
      stat.max_duration_ms = duration_ms
    end
    stat.avg_duration_ms = math.floor(stat.duration_ms / math.max(stat.timed_results, 1) + 0.5)
  end

  local content = type(msg.content) == "string" and msg.content or ""
  if is_failure_tool_result(msg) then
    stat.failed = stat.failed + 1
  else
    stat.success = stat.success + 1
  end
  if msg._meta and msg._meta.ttl_result then
    stat.ttl_notices = stat.ttl_notices + 1
  end
  if content:find("Tool result discarded by keep", 1, true) then
    stat.discarded = stat.discarded + 1
  end
  if content:find("Output exceeded", 1, true) or content:find("Full log saved to:", 1, true) then
    stat.oversized = stat.oversized + 1
  end
end

local function extract_inner_calls(outer_name, args)
  local decoded = decode_arguments(args)
  local inner = {}
  if outer_name == "run" and type(decoded) == "table" and decoded.scope == "tool" and type(decoded.command) == "string" then
    table.insert(inner, { name = decoded.command, input_bytes = byte_len(decoded.args or {}) })
  elseif outer_name == "call" and type(decoded) == "table" then
    local name = decoded.tool
    local input_bytes = byte_len(decoded.params or {})
    if type(name) == "string" and name ~= "" then
      table.insert(inner, { name = name, input_bytes = input_bytes })
    end
  elseif outer_name == "multicall" and type(decoded) == "table" and type(decoded.calls) == "table" then
    for _, call in ipairs(decoded.calls) do
      if type(call) == "table" and type(call.tool) == "string" then
        table.insert(inner, {
          name = call.tool,
          input_bytes = byte_len(call.params or {}),
          label = call.label,
        })
      end
    end
  end
  return inner
end

local function analyze_tools(messages)
  local tool = {
    outer = {},
    inner = {},
    call_id_to_outer = {},
    call_id_to_inner = {},
    orphan_results = 0,
    pending_calls = 0,
  }

  for index, msg in ipairs(messages) do
    if has_tool_calls(msg) then
      for _, call in ipairs(iter_tool_calls(msg)) do
        local input_bytes = byte_len(call.arguments or {})
        local outer_stat = add_tool_input(tool.outer, call.name, input_bytes, index)
        if call.id then
          tool.call_id_to_outer[call.id] = outer_stat
        end

        local inners = extract_inner_calls(call.name, call.arguments)
        for _, inner in ipairs(inners) do
          local inner_stat = add_tool_input(tool.inner, inner.name, inner.input_bytes or 0, index)
          if call.id then
            tool.call_id_to_inner[call.id] = tool.call_id_to_inner[call.id] or {}
            table.insert(tool.call_id_to_inner[call.id], inner_stat)
          end
        end
      end
    elseif msg.role == "tool" then
      local call_id = get_tool_call_id(msg)
      local outer_stat = call_id and tool.call_id_to_outer[call_id] or nil
      if outer_stat then
        add_tool_output(outer_stat, msg)
        outer_stat.latest_index = index
      else
        tool.orphan_results = tool.orphan_results + 1
      end

      local inner_stats = call_id and tool.call_id_to_inner[call_id] or nil
      if type(inner_stats) == "table" then
        local content = type(msg.content) == "string" and msg.content or safe_json(msg.content)
        local decoded = decode_arguments(content)
        local duration_share = msg._meta
          and type(msg._meta.duration_ms) == "number"
          and math.floor(msg._meta.duration_ms / math.max(#inner_stats, 1) + 0.5)
          or nil
        if type(decoded) == "table" and type(decoded.results) == "table" then
          for child_index, stat in ipairs(inner_stats) do
            local child = decoded.results[child_index]
            local child_bytes = child and byte_len(child.result or child.error or child) or 0
            if child_bytes <= 0 then
              child_bytes = math.floor(byte_len(content) / math.max(#inner_stats, 1) + 0.5)
            end
            local child_duration = child and type(child.duration_ms) == "number" and child.duration_ms or duration_share
            local pseudo = vim.tbl_extend("force", msg, { content = child and safe_json(child) or content })
            pseudo._meta = vim.tbl_extend("force", msg._meta or {}, {
              output_bytes = child_bytes,
              duration_ms = child_duration,
            })
            add_tool_output(stat, pseudo)
            stat.latest_index = index
          end
        else
          local share = math.floor(byte_len(content) / math.max(#inner_stats, 1) + 0.5)
          for _, stat in ipairs(inner_stats) do
            local pseudo = vim.tbl_extend("force", msg, { content = content:sub(1, share) })
            pseudo._meta = vim.tbl_extend("force", msg._meta or {}, {
              output_bytes = share,
              duration_ms = duration_share,
            })
            add_tool_output(stat, pseudo)
            stat.latest_index = index
          end
        end
      end
    end
  end

  for _, stat in pairs(tool.outer) do
    local done = stat.success + stat.failed
    if stat.calls > done then
      tool.pending_calls = tool.pending_calls + (stat.calls - done)
    end
  end

  return tool
end

local function sorted_stats(map)
  local list = {}
  for _, stat in pairs(map or {}) do
    table.insert(list, stat)
  end
  table.sort(list, function(a, b)
    local at = (a.input_tokens or 0) + (a.output_tokens or 0)
    local bt = (b.input_tokens or 0) + (b.output_tokens or 0)
    if at == bt then
      return a.name < b.name
    end
    return at > bt
  end)
  return list
end

local function first_match(content, patterns)
  if type(content) ~= "string" then
    return nil
  end
  for _, pattern in ipairs(patterns) do
    local value = content:match(pattern)
    if type(value) == "string" and value ~= "" then
      return value
    end
  end
  return nil
end

local function add_unique(list, seen, value)
  if type(value) ~= "string" or value == "" or seen[value] then
    return
  end
  seen[value] = true
  table.insert(list, value)
end

local function ensure_bucket(map, key)
  key = key or "unknown"
  map[key] = map[key] or {
    count = 0,
    content_bytes = 0,
    json_bytes = 0,
    estimated_tokens = 0,
  }
  return map[key]
end

local function add_message_bucket(map, key, content_bytes, json_bytes)
  local bucket = ensure_bucket(map, key)
  bucket.count = bucket.count + 1
  bucket.content_bytes = bucket.content_bytes + content_bytes
  bucket.json_bytes = bucket.json_bytes + json_bytes
  bucket.estimated_tokens = bucket.estimated_tokens + estimate_tokens(json_bytes)
end

local CLEANED_TOOL_NAMES = {
  ["@session:compact_self"] = true,
}

local ABILITY_CONTEXT_TAGS = {
  ability_revision = true,
  ability_instructions = true,
  ability_guidance = true,
  ability_reference = true,
  ability_hook = true,
  ability_hook_tombstone = true,
}

local function get_meta(msg)
  return type(msg) == "table" and (msg._meta or (msg.opts and msg.opts._meta) or {}) or {}
end

local function get_meta_tag(msg)
  return get_meta(msg).tag
end

local function get_message_compact_category(msg, index, protected_prefix_count)
  local tag = get_meta_tag(msg)
  if index <= protected_prefix_count then
    return "protected_prefix"
  end
  if msg and msg.role == "system" then
    return "system_message"
  end
  if tag == "system_prompt_from_config" or tag == "rules" then
    return "initial_rules_context"
  end
  if tag == "compact_summary" then
    return "compact_summary"
  end
  local meta = get_meta(msg)
  if tag == "context_file" or ABILITY_CONTEXT_TAGS[tag] or type(meta.ability_catalogs) == "table" then
    return "loaded_item_context"
  end
  if tag == "default_session_cache_warmup" or tag == "default_session_cache_warmup_response" then
    return "prompt_cache_warmup"
  end
  return nil
end

local function message_has_cleaned_tool_call(msg)
  if type(msg) ~= "table" then
    return false
  end
  for _, call in ipairs(iter_tool_calls(msg)) do
    if CLEANED_TOOL_NAMES[call.name] then
      return true
    end
  end
  return false
end

local function is_cleaned_tool_result(msg)
  if type(msg) ~= "table" or msg.role ~= "tool" then
    return false
  end
  local content = type(msg.content) == "string" and msg.content or ""
  return content:find("compact_self", 1, true) ~= nil
end

local function analyze_compact_retention(messages, source)
  local protected_prefix_count = 0
  if type(source) == "table" and source.chat then
    local ok, compaction_messages = pcall(require, "maxa.session.compaction_messages")
    if ok and type(compaction_messages.get_protected_prefix_count) == "function" then
      protected_prefix_count = compaction_messages.get_protected_prefix_count(source.chat)
    end
  elseif type(source) == "table" and source.chat_data then
    local ok, compaction_messages = pcall(require, "maxa.session.compaction_messages")
    if ok and type(compaction_messages.get_protected_prefix_count) == "function" then
      protected_prefix_count = compaction_messages.get_protected_prefix_count(source.chat_data)
    end
  end

  local stats = {
    protected_prefix_count = protected_prefix_count,
    preserved = { total = { count = 0, content_bytes = 0, json_bytes = 0, estimated_tokens = 0 } },
    cleaned = { total = { count = 0, content_bytes = 0, json_bytes = 0, estimated_tokens = 0 } },
  }

  for index, msg in ipairs(messages or {}) do
    local content_bytes = byte_len(msg.content or "")
    local json_bytes = byte_len(msg)
    local category = get_message_compact_category(msg, index, protected_prefix_count)
    if category then
      add_message_bucket(stats.preserved, category, content_bytes, json_bytes)
      add_message_bucket(stats.preserved, "total", content_bytes, json_bytes)
    end

    local tag = get_meta_tag(msg)
    if tag == "token_warning" then
      add_message_bucket(stats.cleaned, "token_warning", content_bytes, json_bytes)
      add_message_bucket(stats.cleaned, "total", content_bytes, json_bytes)
    elseif message_has_cleaned_tool_call(msg) then
      add_message_bucket(stats.cleaned, "compact_self_tool_call", content_bytes, json_bytes)
      add_message_bucket(stats.cleaned, "total", content_bytes, json_bytes)
    elseif is_cleaned_tool_result(msg) then
      add_message_bucket(stats.cleaned, "compact_self_tool_result", content_bytes, json_bytes)
      add_message_bucket(stats.cleaned, "total", content_bytes, json_bytes)
    end
  end

  return stats
end

local function analyze_messages(messages)
  local counts = {
    total = #messages,
    system = 0,
    user = 0,
    llm = 0,
    tool_call = 0,
    tool_result = 0,
    other = 0,
  }
  local meta_tags = {}
  local message_stats = {}
  local meta_tag_stats = {}
  local loaded = {
    abilities = {},
    contexts = {},
    rules = {},
  }
  local seen_loaded = {
    abilities = {},
    contexts = {},
    rules = {},
  }
  local content_bytes = 0

  for _, msg in ipairs(messages) do
    local role = msg.role
    local kind
    if role == "system" then
      kind = "system"
      counts.system = counts.system + 1
    elseif role == "user" then
      kind = "user"
      counts.user = counts.user + 1
    elseif role == "assistant" or role == "llm" then
      if has_tool_calls(msg) then
        kind = "assistant tool_call"
        counts.tool_call = counts.tool_call + 1
      else
        kind = "assistant text"
        counts.llm = counts.llm + 1
      end
    elseif role == "tool" then
      kind = "tool_result"
      counts.tool_result = counts.tool_result + 1
    else
      kind = "other"
      counts.other = counts.other + 1
    end

    local msg_content_bytes = byte_len(msg.content or "")
    local msg_json_bytes = byte_len(msg)
    content_bytes = content_bytes + msg_content_bytes
    add_message_bucket(message_stats, kind, msg_content_bytes, msg_json_bytes)
    add_message_bucket(message_stats, "total", msg_content_bytes, msg_json_bytes)
    local meta = get_meta(msg)
    if meta.tag then
      add_count(meta_tags, meta.tag)
      add_message_bucket(meta_tag_stats, meta.tag, msg_content_bytes, msg_json_bytes)
    end

    local content = type(msg.content) == "string" and msg.content or ""
    local ability = type(meta.ability) == "table" and meta.ability or nil
    if ability and type(ability.name) == "string" then
      add_unique(loaded.abilities, seen_loaded.abilities, ability.name)
    end
    if type(meta.ability_catalogs) == "table" then
      for name in pairs(meta.ability_catalogs) do
        if type(name) == "string" then
          add_unique(loaded.abilities, seen_loaded.abilities, name)
        end
      end
    end
    if meta.tag == "context_file" then
      add_unique(loaded.contexts, seen_loaded.contexts, (msg.context and msg.context.id) or first_match(content, {
        "^###%s*([^\n]+)",
        "^#%s*([^\n]+)",
      }))
    elseif meta.tag == "rules" then
      add_unique(loaded.rules, seen_loaded.rules, first_match(content, {
        "^###%s*([^\n]+)",
        "^#%s*([^\n]+)",
      }) or "rules")
    end
  end

  table.sort(loaded.abilities)
  table.sort(loaded.contexts)
  table.sort(loaded.rules)

  return counts, meta_tags, content_bytes, loaded, message_stats, meta_tag_stats
end

local function build_stats(source, status, messages, fallback)
  fallback = fallback or {}
  local counts, meta_tags, content_bytes, loaded, message_stats, meta_tag_stats = analyze_messages(messages)
  local compact_retention = analyze_compact_retention(messages, fallback)
  local tool = analyze_tools(messages)

  return {
    source = source,
    chat = fallback.chat,
    save_id = status and status.save_id or fallback.save_id,
    title = status and status.title or fallback.title,
    adapter = status and status.adapter or fallback.adapter,
    model = status and status.model or fallback.model,
    token = status and {
      used = status.tokens,
      limit = status.token_limit,
      percent = status.token_percent,
      source = status.token_source or "unknown",
    } or {},
    messages_json_bytes = status and status.messages_json_bytes or byte_len(messages),
    message_content_bytes = content_bytes,
    message_counts = counts,
    message_stats = message_stats,
    meta_tags = meta_tags,
    meta_tag_stats = meta_tag_stats,
    loaded = loaded,
    compact_retention = compact_retention,
    tools = {
      outer = sorted_stats(tool.outer),
      inner = sorted_stats(tool.inner),
      orphan_results = tool.orphan_results,
      pending_calls = tool.pending_calls,
    },
  }
end

function M.collect(chat)
  if type(chat) ~= "table" then
    return nil, "No Maxa AI chat found"
  end

  local messages = chat.messages or {}
  local status = session_status.from_chat(chat)
  return build_stats("current", status, messages, {
    chat = chat,
    save_id = chat.opts and chat.opts.save_id,
    title = chat.opts and chat.opts.title or chat.title,
    adapter = chat.adapter and chat.adapter.name,
    model = chat.adapter and chat.adapter.model and chat.adapter.model.name,
  })
end

function M.collect_chat_data(chat_data, save_id)
  if type(chat_data) ~= "table" then
    return nil, "No history chat data found"
  end

  local messages = chat_data.messages or {}
  local status = session_status.from_chat_data(chat_data, save_id)
  return build_stats("history", status, messages, {
    chat_data = chat_data,
    save_id = save_id or chat_data.save_id,
    title = chat_data.title,
    adapter = chat_data.adapter,
    model = chat_data.settings and chat_data.settings.model,
  })
end

M.estimate_tokens = estimate_tokens
M.byte_len = byte_len

return M
