local token_usage = require("maxa.session.token_usage")

local M = {}

local function as_number(value)
  if type(value) == "number" and value > 0 then
    return value
  end
  if type(value) == "string" then
    local n = tonumber(value)
    if n and n > 0 then
      return n
    end
  end
  return nil
end

local function safe_json_bytes(value)
  local ok, encoded = pcall(vim.json.encode, value or {})
  if ok and type(encoded) == "string" then
    return #encoded
  end
  return 0
end

local function get_adapter_name(adapter)
  if type(adapter) ~= "table" then
    return nil
  end
  if type(adapter.name) == "string" and adapter.name ~= "" then
    return adapter.name
  end
  if adapter.schema and type(adapter.schema.name) == "string" and adapter.schema.name ~= "" then
    return adapter.schema.name
  end
  return nil
end

local function get_model_name(adapter, chat_state, chat_data)
  if type(chat_state) == "table" and type(chat_state.model) == "string" and chat_state.model ~= "" then
    return chat_state.model
  end
  if type(chat_data) == "table" and type(chat_data.settings) == "table" and type(chat_data.settings.model) == "string" then
    return chat_data.settings.model
  end
  if type(adapter) == "table" then
    if adapter.model and type(adapter.model) == "table" and type(adapter.model.name) == "string" then
      return adapter.model.name
    end
    if adapter.schema and adapter.schema.model then
      local default = adapter.schema.model.default
      if type(default) == "string" then
        return default
      elseif type(default) == "function" then
        local ok, result = pcall(default, adapter)
        if ok and type(result) == "string" then
          return result
        end
      end
    end
  end
  return nil
end

local function estimate_tokens(messages)
  if type(messages) ~= "table" then
    return nil
  end

  local total_chars = 0
  for _, msg in ipairs(messages) do
    if type(msg) == "table" then
      if type(msg.content) == "string" then
        total_chars = total_chars + #msg.content
      end
      if type(msg.tool_calls) == "table" then
        for _, tc in ipairs(msg.tool_calls) do
          local fn = type(tc) == "table" and tc["function"] or nil
          if type(fn) == "table" and type(fn.arguments) == "string" then
            total_chars = total_chars + #fn.arguments
          end
        end
      end
      if type(msg.tools) == "table" then
        total_chars = total_chars + safe_json_bytes(msg.tools)
      end
      if type(msg.reasoning) == "table" and type(msg.reasoning.content) == "string" then
        local tainted = msg._meta and msg._meta.reasoning_tainted
        if not tainted then
          total_chars = total_chars + #msg.reasoning.content
        end
      end
    end
  end

  if total_chars <= 0 then
    return nil
  end
  return math.floor(total_chars / 2.5)
end

local function get_save_id(chat, fallback)
  if type(chat) == "table" then
    local ok, sub_utils = pcall(require, "maxa.mcphub.native_servers.subagent.utils")
    if ok and type(sub_utils.get_chat_save_id) == "function" then
      local save_id = sub_utils.get_chat_save_id(chat)
      if type(save_id) == "string" and save_id ~= "" then
        return save_id
      end
    end
    if chat.opts and type(chat.opts.save_id) == "string" and chat.opts.save_id ~= "" then
      return chat.opts.save_id
    end
    if type(chat.save_id) == "string" and chat.save_id ~= "" then
      return chat.save_id
    end
  end
  return fallback
end

local function status_from_parts(parts)
  local messages = parts.messages
  local message_count = type(messages) == "table" and #messages or 0
  local tokens = parts.tokens
  local token_source = parts.token_source or "unknown"
  local limit = parts.limit
  local percent = parts.percent

  if tokens and limit then
    percent = math.floor((tokens / limit) * 100 + 0.5)
  end

  return {
    save_id = parts.save_id,
    title = parts.title,
    adapter = parts.adapter,
    model = parts.model,
    tokens = tokens,
    token_limit = limit,
    token_percent = percent,
    token_source = token_source,
    messages_json_bytes = safe_json_bytes(messages or {}),
    message_count = message_count,
    updated_at = parts.updated_at or os.time(),
  }
end

function M.from_chat(chat, chat_state)
  if type(chat) ~= "table" then
    return nil
  end

  local usage = token_usage.get_usage(chat, chat_state)
  local tokens = usage and usage.tokens or token_usage.get_token_count(chat, chat_state)
  local limit = usage and usage.context_window or token_usage.get_context_window(chat, chat_state)
  local percent = usage and usage.percent or nil
  local source = tokens and "actual" or "unknown"

  if not tokens then
    tokens = estimate_tokens(chat.messages)
    if tokens then
      source = "estimated"
    end
  end

  return status_from_parts({
    save_id = get_save_id(chat),
    title = chat.title or chat.opts and chat.opts.title,
    adapter = get_adapter_name(chat.adapter),
    model = get_model_name(chat.adapter, chat_state),
    messages = chat.messages,
    tokens = tokens,
    token_source = source,
    limit = limit,
    percent = percent,
  })
end

function M.from_chat_data(chat_data, save_id)
  if type(chat_data) ~= "table" then
    return nil
  end

  local meta = type(chat_data._meta) == "table" and chat_data._meta.maxa_ai_status or nil
  local messages = chat_data.messages or {}
  local tokens = meta and as_number(meta.tokens) or nil
  local model = chat_data.settings and chat_data.settings.model or nil
  local limit = meta and as_number(meta.context_limit)
    or token_usage.get_context_window(nil, { adapter = { name = chat_data.adapter }, model = model })
  local percent = meta and as_number(meta.token_percent) or nil
  local source = tokens and "meta" or "unknown"

  if not tokens then
    tokens = estimate_tokens(messages)
    if tokens then
      source = "estimated"
    end
  end

  return status_from_parts({
    save_id = chat_data.save_id or save_id,
    title = chat_data.title,
    adapter = chat_data.adapter,
    model = model,
    messages = messages,
    tokens = tokens,
    token_source = source,
    limit = limit,
    percent = percent,
    updated_at = chat_data.updated_at,
  })
end

function M.from_messages(messages, opts)
  opts = opts or {}
  local tokens = estimate_tokens(messages)
  return status_from_parts({
    save_id = opts.save_id,
    title = opts.title,
    adapter = opts.adapter,
    model = opts.model,
    messages = messages,
    tokens = tokens,
    token_source = tokens and "estimated" or "unknown",
    limit = opts.token_limit,
    updated_at = opts.updated_at,
  })
end

local function to_public(status)
  if type(status) ~= "table" then
    return nil
  end
  return {
    save_id = status.save_id,
    tokens = {
      used = status.tokens,
      limit = status.token_limit,
      percent = status.token_percent,
      source = status.token_source or "unknown",
    },
    messages_json_bytes = status.messages_json_bytes or 0,
    message_count = status.message_count or 0,
  }
end

function M.to_llm(status)
  return to_public(status)
end

function M.to_hook(status)
  return to_public(status)
end

function M.current_from_req(req)
  local chat = req
    and req.caller
    and req.caller.maxa_ai
    and req.caller.maxa_ai.chat
    or nil
  return M.from_chat(chat)
end

function M.current_from_bufnr(bufnr)
  if type(bufnr) ~= "number" or bufnr <= 0 or not vim.api.nvim_buf_is_valid(bufnr) then
    return nil
  end

  local ok, maxa_ai = pcall(require, "maxa")
  if not ok or type(maxa_ai.buf_get_chat) ~= "function" then
    return nil
  end

  local success, chat = pcall(maxa_ai.buf_get_chat, bufnr)
  if success and type(chat) == "table" then
    return M.from_chat(chat)
  end
  return nil
end

return M
