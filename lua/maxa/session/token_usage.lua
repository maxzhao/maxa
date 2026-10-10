local runtime_state = require("maxa.state")
local model_limits = require("maxa.session.model_limits")

local M = {}
local observers = setmetatable({}, { __mode = "k" })
local pending = setmetatable({}, { __mode = "k" })

-- Only live consumers opt in. Message/usage bursts coalesce without polling.
function M.observe(chat, callback)
  observers[chat] = observers[chat] or {}
  observers[chat][callback] = true
  return function()
    if observers[chat] then observers[chat][callback] = nil end
  end
end

function M.notify(chat)
  if not observers[chat] or not next(observers[chat]) or pending[chat] then return end
  pending[chat] = true
  vim.schedule(function()
    pending[chat] = nil
    for callback in pairs(observers[chat] or {}) do pcall(callback) end
  end)
end

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

local function get_model_name(adapter, chat_state)
  if type(adapter) == "table" then
    -- 优先使用运行时模型名（用户可能通过 settings 切换了模型）
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

  if type(chat_state) == "table" and type(chat_state.model) == "string" and chat_state.model ~= "" then
    return chat_state.model
  end

  return nil
end

local function tokens_from_metadata(bufnr)
  if not bufnr or type(runtime_state.chat_metadata) ~= "table" then
    return nil
  end

  local metadata = runtime_state.chat_metadata[bufnr]
  if type(metadata) ~= "table" then
    return nil
  end

  return as_number(metadata.tokens)
end

local function tokens_from_chat_meta(chat)
  if type(chat) ~= "table" or type(chat._meta) ~= "table" then
    return nil
  end
  local status = chat._meta.maxa_ai_status
  if type(status) ~= "table" then
    return nil
  end
  return as_number(status.tokens)
end

function M.get_token_count(chat, chat_state)
  return as_number(chat and chat.ui and chat.ui.tokens)
    or tokens_from_chat_meta(chat)
    or tokens_from_metadata(chat_state and chat_state.bufnr)
    or as_number(chat and chat.adapter and chat.adapter._total_tokens)
    or as_number(chat_state and chat_state.adapter and chat_state.adapter._total_tokens)
    or as_number(chat_state and chat_state.last_tokens)
end

function M.get_context_window(chat, chat_state)
  local adapter = chat and chat.adapter or chat_state and chat_state.adapter
  local model_name = get_model_name(adapter, chat_state)
  if type(model_name) ~= "string" or model_name == "" then
    return nil
  end

  return model_limits.get_context_window(model_name, get_adapter_name(adapter))
end

function M.get_usage(chat, chat_state)
  local tokens = M.get_token_count(chat, chat_state)
  local context_window = M.get_context_window(chat, chat_state)
  if not tokens or not context_window then
    return nil
  end

  local ratio = tokens / context_window
  return {
    tokens = tokens,
    context_window = context_window,
    ratio = ratio,
    percent = math.floor(ratio * 100 + 0.5),
  }
end

function M.persist_status(chat, chat_state)
  if type(chat) ~= "table" then
    return nil
  end

  local tokens = M.get_token_count(chat, chat_state)
  local context_window = M.get_context_window(chat, chat_state)
  if not tokens and not context_window then
    return nil
  end

  chat._meta = chat._meta or {}
  local status = chat._meta.maxa_ai_status or {}
  if tokens then
    status.tokens = tokens
  end
  if context_window then
    status.context_limit = context_window
  end
  if tokens and context_window then
    status.token_percent = math.floor((tokens / context_window) * 100 + 0.5)
  end
  status.updated_at = os.time()
  chat._meta.maxa_ai_status = status
  return status
end

function M.set_adapter_context_limit(adapter_name, limit)
  local n = as_number(limit)
  if type(adapter_name) ~= "string" or adapter_name == "" or not n then
    return false
  end
  return model_limits.set_adapter_limit(adapter_name, "context_window", n)
end

function M.set_model_context_window(pattern, limit)
  local n = as_number(limit)
  if type(pattern) ~= "string" or pattern == "" or not n then
    return false
  end
  return model_limits.set_model_limit(pattern, { context_window = n })
end

return M
