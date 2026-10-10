-- Generic TTL lifecycle support for MCP tool results.
--
-- Tools can call mark_current_tool_result(context, opts) before sending their result.
-- The actual tool_result message does not exist at handler time, so this module
-- stores a pending marker by tool_call_id. maxa.interactions.chat.tools.display attaches the
-- marker to the corresponding tool_result after MaxaAI writes it.
--
-- TTL metadata is in the owning result header, before the source separator.
-- Never append it to source text or inject a separate user instruction. Stored
-- insertion provenance makes defer/keep/persist preserve all source bytes.

local M = {}

local EXPIRED_MSG = "⚠️ Tool result expired and removed from context (TTL reached)."
local DISCARDED_MSG = "⚠️ Tool result discarded by keep."

---@type table<string, table>
local pending = {}

local function normalize_ttl(ttl, default)
  ttl = tonumber(ttl)
  if not ttl then
    ttl = default or 1
  end
  ttl = math.floor(ttl)
  if ttl < 1 then
    ttl = 1
  end
  return ttl
end

local function get_chat_and_tool_call_id(context, explicit_call_id)
  local chat = context and context.chat or nil
  local call_id = explicit_call_id or (context and context.tool_call_id) or nil
  if type(chat) ~= "table" then
    return nil, call_id
  end
  return chat, call_id
end

local function get_tool_call_id(msg)
  return msg and msg.role == "tool" and msg.tools and msg.tools.call_id or msg and msg.tool_call_id or nil
end

local function count_llm_messages_after(messages, after_index)
  local count = 0
  for i = after_index + 1, #messages do
    local role = messages[i] and messages[i].role
    if role == "llm" or role == "assistant" then
      count = count + 1
    end
  end
  return count
end

local function find_tool_result_index(messages, tool_call_id)
  if not tool_call_id or tool_call_id == "" then
    return nil
  end
  for i, msg in ipairs(messages or {}) do
    local tools = msg and msg.tools or nil
    local ttl_meta = msg and msg._meta and msg._meta.ttl_result or nil
    if get_tool_call_id(msg) == tool_call_id
      or (tools and tools.id == tool_call_id)
      or (ttl_meta and ttl_meta.call_id == tool_call_id)
    then
      return i
    end
  end
  return nil
end

local FOOTER_BEGIN = "<!-- maxa-ttl-result:start -->"
local FOOTER_END = "<!-- maxa-ttl-result:end -->"

local function decode_args(args)
  if type(args) == "string" then
    local ok, decoded = pcall(vim.json.decode, args)
    args = ok and decoded or nil
  end
  return type(args) == "table" and args or nil
end

local function read_request(call)
  local fn = call and call["function"]
  if type(fn) ~= "table" then
    return nil
  end
  local args = decode_args(fn.arguments)
  if not args then
    return nil
  end
  if fn.name == "run" then
    local opts = decode_args(args.opts) or {}
    if args.scope ~= "tool" or args.command ~= "read" or opts.async == true then return nil end
    args = decode_args(args.args)
  elseif fn.name == "call" then
    if args.tool ~= "read" or (args.json_patches and args.json_patches ~= vim.NIL) or args.async == true then
      return nil
    end
    args = decode_args(args.params)
  elseif fn.name ~= "read" then
    return nil
  end
  if not args or type(args.path) ~= "string" or args.path == "" then
    return nil
  end
  local has_range = args.start_line ~= nil or args.end_line ~= nil
  return {
    path = args.path,
    start_line = has_range and tonumber(args.start_line or 1) or nil,
    end_line = has_range and tonumber(args.end_line or -1) or nil,
    force = args.force == true,
    result_policy = args.result_policy or "auto",
  }
end

local function repeated_expired_read(messages, result_index, call_id)
  if not result_index then
    return false
  end
  local calls = {}
  for i = 1, result_index - 1 do
    local msg = messages[i]
    if msg and (msg.role == "llm" or msg.role == "assistant") and msg.tools and type(msg.tools.calls) == "table" then
      for _, call in ipairs(msg.tools.calls) do
        local id = type(call) == "table" and (call.call_id or call.id)
        if id then
          calls[id] = call
        end
      end
    end
  end
  local request = read_request(calls[call_id])
  if not request then
    return false
  end
  for i = result_index - 1, 1, -1 do
    local msg = messages[i]
    if msg and msg.role == "tool" then
      local previous_id = get_tool_call_id(msg)
      if previous_id and vim.deep_equal(request, read_request(calls[previous_id])) then
        local meta = msg._meta and msg._meta.ttl_result
        return meta ~= nil and meta.expired == true
      end
    end
  end
  return false
end

-- Read only to recognize the exact suffix attached by older runtimes.
local function legacy_footer_content(tool_call_id, ttl, repeated)
  local lines = {
    FOOTER_BEGIN,
    string.format(
      "TTL result: tool_call_id=%s expires in %d LLM round(s).",
      tostring(tool_call_id),
      tonumber(ttl) or 1
    ),
    "If the default expiry is not OK, immediately call keep with that tool_call_id and action=discard|defer|keep|persist.",
  }
  if repeated then
    lines[#lines + 1] = string.format(
      "Runtime notice: An identical read expired earlier in this Chat. If you need this result with other material, immediately call keep with tool_call_id=%s and action=keep before reading more.",
      tostring(tool_call_id)
    )
  end
  lines[#lines + 1] = FOOTER_END
  return table.concat(lines, "\n")
end

local function strip_ttl_metadata(msg)
  local content = msg.content or ""
  local meta = msg._meta and msg._meta.ttl_result
  if not meta then return content end
  local offset, inserted = meta.header_offset, meta.header_text
  if offset and inserted and content:sub(offset, offset + #inserted - 1) == inserted then
    content = content:sub(1, offset - 1) .. content:sub(offset + #inserted)
  elseif not inserted and meta.call_id then
    local suffix = "\n\n" .. legacy_footer_content(meta.call_id, meta.ttl, meta.repeated_read)
    if content:sub(-#suffix) == suffix then content = content:sub(1, #content - #suffix) end
  end
  meta.header_offset, meta.header_text = nil, nil
  return content
end

local function header_content(tool_call_id, ttl, repeated)
  local lines = {
    "tool_call_id: " .. tostring(tool_call_id),
    string.format("ttl: %d LLM rounds", tonumber(ttl) or 1),
  }
  if repeated then
    lines[#lines + 1] = "ttl_notice: identical read previously expired; retain before loading more if needed"
  end
  return table.concat(lines, "\n") .. "\n"
end

local function set_ttl_footer(msg, tool_call_id, ttl, repeated, fresh)
  if not msg then return end
  local base = fresh and (msg.content or "") or strip_ttl_metadata(msg)
  local prefix = base:match("^(next_cursor: [^\n]+\n)%-%-%-\n")
  local metadata = header_content(tool_call_id, ttl, repeated)
  if prefix then
    local offset = #prefix + 1
    msg.content = prefix .. metadata .. base:sub(offset)
    msg._meta.ttl_result.header_offset = offset
    msg._meta.ttl_result.header_text = metadata
  else
    -- Generic managed results also keep lifecycle facts ahead of their body.
    local inserted = metadata .. "---\n"
    msg.content = inserted .. base
    msg._meta.ttl_result.header_offset = 1
    msg._meta.ttl_result.header_text = inserted
  end
end

local function clear_ttl_footer(msg)
  if msg then msg.content = strip_ttl_metadata(msg) end
end

-- Reserve lifecycle metadata before cursor chunking; the display attaches it
-- only after the canonical tool result exists. No source bytes are discarded.
function M.read_header_reserve(context)
  if not context or not context.chat or not context.tool_call_id then return 0 end
  return #header_content(context.tool_call_id, 3, true)
end

local function delete_notice(messages, tool_call_id)
  local deleted = 0
  for i = #(messages or {}), 1, -1 do
    local msg = messages[i]
    if msg and msg._meta and msg._meta.tag == "ttl_notice" and msg._meta.ttl_notice_for == tool_call_id then
      table.remove(messages, i)
      deleted = deleted + 1
    end
  end
  return deleted
end

local function migrate_legacy_notices(chat)
  local messages = chat and chat.messages
  if not messages then
    return 0
  end

  local migrated = 0
  for i = #messages, 1, -1 do
    local notice = messages[i]
    if notice and notice._meta and notice._meta.tag == "ttl_notice" then
      local call_id = notice._meta.ttl_notice_for
      local tool_msg = call_id and select(1, M.find_tool_result(chat, call_id)) or nil
      local ttl_meta = tool_msg and tool_msg._meta and tool_msg._meta.ttl_result
      if tool_msg and ttl_meta and ttl_meta.enabled ~= false and ttl_meta.policy == "expire" then
        set_ttl_footer(tool_msg, call_id, ttl_meta.ttl, ttl_meta.repeated_read)
      end
      table.remove(messages, i)
      migrated = migrated + 1
    end
  end
  return migrated
end

local function cleanup_tool_result(msg, reason)
  msg._meta = msg._meta or {}
  local meta = msg._meta.ttl_result or {}
  local cleanup = meta.cleanup or "content"

  if cleanup == "image" and msg._meta then
    local seen = {}
    local function expire_image(image)
      if type(image) ~= "table" or seen[image] then
        return
      end
      seen[image] = true
      image.base64 = nil
      image.expired = true
    end

    expire_image(msg._meta.image)
    if type(msg._meta.images) == "table" then
      for _, image in ipairs(msg._meta.images) do
        expire_image(image)
      end
    end
  end

  if msg._meta.presentation then
    local view = msg._meta.presentation.result
    if view then view.blocks = {} end
    msg._meta.presentation.request = nil
  end
  msg._meta.subagent_content, msg._meta.tool_batch_content = nil, nil
  msg.content = reason == "discard" and DISCARDED_MSG or EXPIRED_MSG
  meta.policy = reason == "discard" and "discarded" or "expired"
  meta.display_state = meta.policy
  meta.enabled = false
  meta.persistent = false
  meta.expired = reason ~= "discard"
  meta.discarded = reason == "discard"
  msg._meta.ttl_result = meta
end

---Mark the current tool call result for lifecycle management.
---The default policy is TTL expiry; callers may also use policy="persist" to reuse the
---same metadata path for compression protection without scheduling expiry.
---@param context table Exact Chat invocation context
---@param opts table {ttl:number, cleanup:"content"|"image", policy:string|nil, persistent:boolean|nil, enabled:boolean|nil, display_state:string|nil}
---@return boolean ok
---@return string|nil err
function M.mark_current_tool_result(context, opts)
  opts = opts or {}
  local _, call_id = get_chat_and_tool_call_id(context, opts.tool_call_id or opts.call_id)
  if not call_id or call_id == "" then
    return false, "Cannot determine current tool_call_id"
  end

  pending[call_id] = {
    ttl = normalize_ttl(opts.ttl, 1),
    cleanup = opts.cleanup or "content",
    policy = opts.policy or "expire",
    persistent = opts.persistent == true,
    enabled = opts.enabled,
    display_state = opts.display_state,
  }
  return true
end

---@param tool_call_id string|nil
---@return table|nil
function M.take_pending(tool_call_id)
  if not tool_call_id or tool_call_id == "" then
    return nil
  end
  local opts = pending[tool_call_id]
  pending[tool_call_id] = nil
  return opts
end

---@param chat table
---@param tool_msg table
---@param tool_call_id string
---@param opts table
---@return boolean
function M.attach_to_tool_result(chat, tool_msg, tool_call_id, opts)
  if not chat or not chat.messages or not tool_msg or not tool_call_id then
    return false
  end

  opts = opts or {}
  local ttl = normalize_ttl(opts.ttl, 1)
  local policy = opts.policy or "expire"
  local persistent = opts.persistent == true or policy == "persist"
  local enabled = opts.enabled
  if enabled == nil then
    enabled = policy == "expire"
  end
  local display_state = opts.display_state or (policy == "persist" and "persist" or "ttl")
  local tr_index = find_tool_result_index(chat.messages, tool_call_id)
  local baseline = tr_index and count_llm_messages_after(chat.messages, tr_index) or 0

  tool_msg._meta = tool_msg._meta or {}
  tool_msg._meta.ttl_result = {
    enabled = enabled,
    call_id = tool_call_id,
    ttl = ttl,
    baseline_llm_count = baseline,
    policy = policy,
    cleanup = opts.cleanup or "content",
    persistent = persistent,
    display_state = display_state,
  }

  if enabled ~= false and policy == "expire" then
    local repeated = repeated_expired_read(chat.messages, tr_index, tool_call_id)
    tool_msg._meta.ttl_result.repeated_read = repeated or nil
    set_ttl_footer(tool_msg, tool_call_id, ttl, repeated, true)
    delete_notice(chat.messages, tool_call_id)
  end
  return true
end

function M.find_tool_result(chat, tool_call_id)
  if not chat or not chat.messages then
    return nil, nil
  end
  local index = find_tool_result_index(chat.messages, tool_call_id)
  return index and chat.messages[index] or nil, index
end

---@param chat table
---@param tool_call_id string
---@param action string
---@param ttl number|nil
---@return boolean ok
---@return string message
function M.apply_action(chat, tool_call_id, action, ttl)
  if not chat or not chat.messages then
    return false, "Cannot access chat session"
  end
  if not tool_call_id or tool_call_id == "" then
    return false, "tool_call_id is required"
  end

  local msg, index = M.find_tool_result(chat, tool_call_id)
  if not msg then
    return false, "No tool result found for tool_call_id: " .. tool_call_id
  end
  local ttl_meta = msg._meta and msg._meta.ttl_result
  if not ttl_meta then
    return false, "Tool result is not TTL-managed: " .. tool_call_id
  end

  if action == "discard" then
    cleanup_tool_result(msg, "discard")
    delete_notice(chat.messages, tool_call_id)
    pcall(function()
      require("maxa.interactions.chat.tools.display").refresh_tool_summary_line(chat, tool_call_id)
    end)
    return true, "Tool result discarded: " .. tool_call_id
  elseif action == "defer" then
    local next_ttl = tonumber(ttl)
    if not next_ttl or next_ttl < 1 then
      return false, "ttl must be a positive integer when action=defer"
    end
    next_ttl = math.floor(next_ttl)
    clear_ttl_footer(msg)
    ttl_meta.enabled = true
    ttl_meta.policy = "expire"
    ttl_meta.display_state = "defer"
    ttl_meta.ttl = next_ttl
    ttl_meta.baseline_llm_count = count_llm_messages_after(chat.messages, index)
    ttl_meta.persistent = false
    ttl_meta.expired = false
    ttl_meta.discarded = false
    msg._meta.ttl_result = ttl_meta
    set_ttl_footer(msg, tool_call_id, next_ttl, ttl_meta.repeated_read)
    delete_notice(chat.messages, tool_call_id)
    pcall(function()
      require("maxa.interactions.chat.tools.display").refresh_tool_summary_line(chat, tool_call_id)
    end)
    return true, string.format("Tool result deferred for %d LLM round(s): %s", next_ttl, tool_call_id)
  elseif action == "keep" then
    ttl_meta.enabled = false
    ttl_meta.policy = "keep"
    ttl_meta.display_state = "keep"
    ttl_meta.persistent = false
    msg._meta.ttl_result = ttl_meta
    clear_ttl_footer(msg)
    delete_notice(chat.messages, tool_call_id)
    pcall(function()
      require("maxa.interactions.chat.tools.display").refresh_tool_summary_line(chat, tool_call_id)
    end)
    return true, "Tool result kept for this session: " .. tool_call_id
  elseif action == "persist" then
    ttl_meta.enabled = false
    ttl_meta.policy = "persist"
    ttl_meta.display_state = "persist"
    ttl_meta.persistent = true
    msg._meta.ttl_result = ttl_meta
    clear_ttl_footer(msg)
    delete_notice(chat.messages, tool_call_id)
    pcall(function()
      require("maxa.interactions.chat.tools.display").refresh_tool_summary_line(chat, tool_call_id)
    end)
    return true, "Tool result persisted across compression: " .. tool_call_id
  end

  return false, "Invalid action: " .. tostring(action)
end

local function process_expired(chat)
  local messages = chat and chat.messages
  if not messages or #messages == 0 then
    return 0
  end

  local cleaned = 0
  local notices_to_delete = {}
  for i, msg in ipairs(messages) do
    if msg and msg.role == "tool" and msg._meta and msg._meta.ttl_result then
      local meta = msg._meta.ttl_result
      if meta.enabled ~= false and meta.policy == "expire" and not meta.expired and not meta.discarded then
        local ttl = tonumber(meta.ttl) or 1
        local baseline = tonumber(meta.baseline_llm_count) or 0
        local current = count_llm_messages_after(messages, i)
        if ttl > 0 and (current - baseline) >= ttl then
          local call_id = meta.call_id or get_tool_call_id(msg)
          cleanup_tool_result(msg, "expired")
          pcall(function()
            require("maxa.interactions.chat.tools.display").refresh_tool_summary_line(chat, call_id)
          end)
          table.insert(notices_to_delete, call_id)
          cleaned = cleaned + 1
        end
      end
    end
  end

  for _, call_id in ipairs(notices_to_delete) do
    delete_notice(messages, call_id)
  end

  return cleaned
end

---Run the TTL lifecycle at the owning Chat submit boundary.
---@param chat table
---@return integer cleaned
function M.before_chat_submit(chat)
  migrate_legacy_notices(chat)
  local cleaned = process_expired(chat)
  if cleaned > 0 then
    vim.notify(string.format("[ttl_result] Cleaned %d expired tool result(s)", cleaned), vim.log.levels.INFO)
  end
  return cleaned
end

function M.is_persistent_tool_result(msg)
  return msg
    and msg.role == "tool"
    and msg._meta
    and msg._meta.ttl_result
    and msg._meta.ttl_result.persistent == true
end

return M
