-- filepath: lua/maxa/runtime/protocol/normalize.lua
--- maxa runtime protocol normalization layer (phase-1 W2).
---
--- Purpose: the single normalized event/usage surface consumed by the
--- orchestrator from every protocol adapter (plan §4.1). Adapters translate
--- provider frames into these events; the orchestrator never sees provider
--- envelopes. Also hosts the usage normalization rules (streaming-usage spec)
--- and the per-call_id UTF-8 tool-argument accumulator (fixture contract:
--- partial tool arguments MUST be accumulated by stable call id and decoded
--- only at the tool boundary).
---
--- Event shapes (type = adapter event kind, `fields` merged verbatim):
---   { type="response_started", request_id=string }
---   { type="message_delta", delta=string, text=string? }   -- text accumulation
---   { type="reasoning_delta", delta=string, text=string? } -- reasoning accumulation
---   { type="tool_call_started", call_id=string, name=string }
---   { type="tool_args_delta", call_id=string, fragment=string }
---   { type="tool_call_completed", call_id=string, encoded_args=string }
---   { type="usage_updated", usage=table }                  -- normalized snapshot
---   { type="finish_reason", reason=string }
---   { type="error", error=table }                          -- typed error (§4.6)
---   { type="completed" }
---
--- Usage rules (streaming-usage spec §Usage):
---   - provider-reported fields are authoritative for the fields they cover;
---   - a local estimate fills unknown fields only and is marked
---     `source: local_estimate`; `total_tokens` is null when its required
---     components are unknown (never zero);
---   - unknown token fields are null (not 0); final correction replaces prior
---     provisional values and is traceable via `updated_at`/`source`.
---
--- Dependencies: maxa.runtime.schema only. Never loads codecompanion.* /
--- mcphub.* / lua/util/hooks/*.
local schema = require("maxa.runtime.schema")

local M = {}

M.name = "protocol.normalize"

--- Adapter event type constants (the orchestrator switches on these).
M.events = {
  response_started = "response_started",
  message_delta = "message_delta",
  reasoning_delta = "reasoning_delta",
  tool_call_started = "tool_call_started",
  tool_args_delta = "tool_args_delta",
  tool_call_completed = "tool_call_completed",
  usage_updated = "usage_updated",
  finish_reason = "finish_reason",
  error = "error",
  completed = "completed",
}

--- Wall-clock in milliseconds (mirrors schema.now_ms).
---@return integer
local function now_ms()
  return schema.now_ms()
end

--- Base event constructor: `{ type = <type>, ...fields }` with a monotonic
--- per-process ordinal attached for deterministic ordering diagnostics.
---@param etype string one of M.events
---@param fields? table extra event fields
---@return table event
function M.event(etype, fields)
  fields = fields or {}
  return vim.tbl_deep_extend("force", { type = etype }, fields)
end

---@param fields? table
---@return table event
function M.response_started(fields)
  return M.event(M.events.response_started, fields)
end

---@param delta string incremental text delta
---@param fields? table { text?: string full accumulated text }
---@return table event
function M.message_delta(delta, fields)
  fields = fields or {}
  fields.delta = delta
  return M.event(M.events.message_delta, fields)
end

---@param delta string incremental reasoning delta
---@param fields? table { text?: string full accumulated reasoning text }
---@return table event
function M.reasoning_delta(delta, fields)
  fields = fields or {}
  fields.delta = delta
  return M.event(M.events.reasoning_delta, fields)
end

---@param call_id string stable runtime call id
---@param name string tool name
---@param fields? table
---@return table event
function M.tool_call_started(call_id, name, fields)
  fields = fields or {}
  fields.call_id = call_id
  fields.name = name
  return M.event(M.events.tool_call_started, fields)
end

---@param call_id string stable runtime call id
---@param fragment string incremental UTF-8 argument fragment
---@param fields? table
---@return table event
function M.tool_args_delta(call_id, fragment, fields)
  fields = fields or {}
  fields.call_id = call_id
  fields.fragment = fragment
  return M.event(M.events.tool_args_delta, fields)
end

---@param call_id string stable runtime call id
---@param encoded_args string fully accumulated encoded arguments (JSON text)
---@param fields? table
---@return table event
function M.tool_call_completed(call_id, encoded_args, fields)
  fields = fields or {}
  fields.call_id = call_id
  fields.encoded_args = encoded_args
  return M.event(M.events.tool_call_completed, fields)
end

---@param usage table normalized usage snapshot (M.normalize_usage output)
---@param fields? table
---@return table event
function M.usage_updated(usage, fields)
  fields = fields or {}
  fields.usage = usage
  return M.event(M.events.usage_updated, fields)
end

---@param reason string finish reason label (e.g. "stop", "length", "tool_calls")
---@param fields? table
---@return table event
function M.finish_reason(reason, fields)
  fields = fields or {}
  fields.reason = reason
  return M.event(M.events.finish_reason, fields)
end

---@param err table typed error (schema.new_error shape)
---@param fields? table
---@return table event
function M.error(err, fields)
  fields = fields or {}
  fields.error = err
  return M.event(M.events.error, fields)
end

---@param fields? table
---@return table event
function M.completed(fields)
  return M.event(M.events.completed, fields)
end

----------------------------------------------------------------------------
-- Usage normalization (streaming-usage spec §Usage)
----------------------------------------------------------------------------

--- Extract the first non-nil integer among candidates (provider field aliases).
---@param raw table provider usage object
---@param keys string[] candidate field names in precedence order
---@return integer|nil value
local function int_of(raw, keys)
  for _, k in ipairs(keys) do
    local v = raw[k]
    if type(v) == "number" and math.floor(v) == v then
      return v
    end
  end
  return nil
end

--- Normalize a provider usage object into the schema.usage snapshot.
--- Provider-reported fields are authoritative; unknown fields stay nil (null).
--- Nested details objects (OpenAI prompt_tokens_details / completion_tokens_details,
--- Anthropic cache fields) are probed defensively (never trusted to exist).
---@param raw table|nil provider usage object (nil => local estimate only)
---@param opts? table {
---   context_limit?: integer|nil   configured model context limit
---   final?: boolean               final snapshot flag (default false)
---   updated_at?: integer|nil      wall-clock ms (default now)
--- }
---@return table usage normalized snapshot (schema.usage shape)
function M.normalize_usage(raw, opts)
  opts = opts or {}
  raw = raw or {}
  local usage = {
    input_tokens = nil,
    output_tokens = nil,
    total_tokens = nil,
    cached_input_tokens = nil,
    cache_creation_input_tokens = nil,
    reasoning_tokens = nil,
    tool_tokens = nil,
    provider_reported_total = nil,
    context_limit = nil,
    context_percent = nil,
    source = "provider_delta",
    final = not not opts.final,
    updated_at = opts.updated_at or now_ms(),
  }

  local provider_known = false
  for _, v in pairs(raw) do
    if v ~= nil then
      provider_known = true
      break
    end
  end
  if not provider_known then
    usage.source = opts.final and "provider_final" or "provider_delta"
    if opts.context_limit ~= nil then
      usage.context_limit = opts.context_limit
    end
    return usage
  end

  -- Token fields: provider aliases per protocol family.
  usage.input_tokens = int_of(raw, { "input_tokens", "prompt_tokens" })
  usage.output_tokens = int_of(raw, { "output_tokens", "completion_tokens" })
  usage.provider_reported_total = int_of(raw, { "total_tokens" })
  if usage.provider_reported_total ~= nil then
    usage.total_tokens = usage.provider_reported_total
  elseif usage.input_tokens ~= nil and usage.output_tokens ~= nil then
    usage.total_tokens = usage.input_tokens + usage.output_tokens
  end
  -- Nested provider details (OpenAI chat.completions).
  local prompt_details = raw.prompt_tokens_details
  if type(prompt_details) == "table" then
    usage.cached_input_tokens = int_of(prompt_details, { "cached_tokens" })
  end
  local completion_details = raw.completion_tokens_details
  if type(completion_details) == "table" then
    usage.reasoning_tokens = int_of(completion_details, { "reasoning_tokens" })
    usage.tool_tokens = int_of(completion_details, { "tool_tokens" })
  end
  -- Anthropic cache fields.
  usage.cache_creation_input_tokens = int_of(raw, { "cache_creation_input_tokens" })
  if usage.cached_input_tokens == nil then
    usage.cached_input_tokens = int_of(raw, { "cache_read_input_tokens" })
  end
  -- Direct passthrough fields (Gemini usageMetadata / Responses usage).
  if usage.reasoning_tokens == nil then
    usage.reasoning_tokens = int_of(raw, { "reasoning_tokens" })
  end
  if usage.tool_tokens == nil then
    usage.tool_tokens = int_of(raw, { "tool_tokens" })
  end
  usage.source = opts.final and "provider_final" or "provider_delta"

  -- Context projection (streaming-usage §Context-limit configuration): the
  -- percentage derives from the configured model context limit only; unknown
  -- limit => no percentage (null), never a guessed default.
  if opts.context_limit ~= nil then
    usage.context_limit = opts.context_limit
    local effective = usage.total_tokens
      or (usage.input_tokens and usage.output_tokens and usage.input_tokens + usage.output_tokens)
    if effective ~= nil and opts.context_limit > 0 then
      usage.context_percent = math.floor((effective / opts.context_limit) * 100)
    end
  end
  return usage
end

--- Local estimate that fills unknown fields only (source: local_estimate).
--- input/output char counts are estimated at ~4 chars/token (deterministic);
--- total is computed only when both components are known (null otherwise).
---@param opts? table { input_chars?: integer, output_chars?: integer,
---                     context_limit?: integer|nil, updated_at?: integer|nil }
---@return table usage normalized snapshot (schema.usage shape)
function M.local_estimate(opts)
  opts = opts or {}
  local function est(chars)
    if type(chars) ~= "number" or chars <= 0 then
      return nil
    end
    return math.max(1, math.floor(chars / 4))
  end
  local input = est(opts.input_chars)
  local output = est(opts.output_chars)
  local usage = {
    input_tokens = input,
    output_tokens = output,
    total_tokens = (input ~= nil and output ~= nil) and (input + output) or nil,
    cached_input_tokens = nil,
    cache_creation_input_tokens = nil,
    reasoning_tokens = nil,
    tool_tokens = nil,
    provider_reported_total = nil,
    context_limit = nil,
    context_percent = nil,
    source = "local_estimate",
    final = true,
    updated_at = opts.updated_at or now_ms(),
  }
  if opts.context_limit ~= nil then
    usage.context_limit = opts.context_limit
    if usage.total_tokens ~= nil and opts.context_limit > 0 then
      usage.context_percent = math.floor((usage.total_tokens / opts.context_limit) * 100)
    end
  end
  return usage
end

--- Validate a normalized usage snapshot against schema.usage.
---@param usage table
---@return boolean ok
---@return string|nil err
function M.validate_usage(usage)
  local verr = schema.validate(schema.usage, usage)
  if verr then
    return false, vim.inspect(verr)
  end
  return true, nil
end

----------------------------------------------------------------------------
-- Transport class -> typed error code mapping (plan §4.2)
----------------------------------------------------------------------------

--- Map a granular transport failure class to a runtime error code.
--- Unknown classes fall back to PROVIDER (never guessed).
---@param class string transport class (transport.CLASS.* value)
---@return string code schema.ERROR.*
function M.class_to_code(class)
  local map = {
    authentication = schema.ERROR.AUTHENTICATION,
    rate_limited = schema.ERROR.RATE_LIMITED,
    quota = schema.ERROR.QUOTA,
    context_limit = schema.ERROR.CONTEXT_LIMIT,
    invalid_request = schema.ERROR.INVALID_REQUEST,
    provider_unavailable = schema.ERROR.PROVIDER_UNAVAILABLE,
    network = schema.ERROR.NETWORK,
    timeout = schema.ERROR.TIMEOUT,
    protocol = schema.ERROR.PROTOCOL,
  }
  if type(class) == "string" and map[class] then
    return map[class]
  end
  return schema.ERROR.PROVIDER
end

--- Build a terminal typed error from a transport-style failure. Keeps the
--- transport cause (status/body/class/provider_type) for diagnostics.
---@param class string transport failure class
---@param message string human-readable detail
---@param cause? table low-level cause fields
---@return table error typed error (terminal)
function M.error_from_class(class, message, cause)
  cause = cause or {}
  cause.class = class
  return schema.new_error(M.class_to_code(class), message, cause, true)
end

----------------------------------------------------------------------------
-- Tool argument accumulator (fixture contract: partial args by stable call id)
----------------------------------------------------------------------------

--- Create a per-call_id UTF-8 tool-argument accumulator.
--- Fragments are appended byte-wise (Lua strings are byte strings; UTF-8
--- multi-byte sequences stay intact across chunk boundaries). Decoding to a
--- Lua table happens ONLY at the tool boundary via M.decode_encoded_args.
---@return table accumulator {
---   feed(call_id, fragment) -> self,
---   get(call_id) -> string|nil,   -- accumulated encoded args
---   reset() -> self }
function M.new_tool_args_accumulator()
  local parts = {}
  return {
    feed = function(self, call_id, fragment)
      if type(call_id) ~= "string" or call_id == "" then
        return self
      end
      if type(fragment) ~= "string" then
        fragment = ""
      end
      local buf = parts[call_id]
      if not buf then
        buf = {}
        parts[call_id] = buf
      end
      buf[#buf + 1] = fragment
      return self
    end,
    get = function(_, call_id)
      local buf = parts[call_id]
      if not buf then
        return nil
      end
      return table.concat(buf)
    end,
    reset = function(self)
      parts = {}
      return self
    end,
  }
end

--- Decode accumulated encoded arguments at the tool boundary.
--- `{}` stays an object (fixture contract: empty JSON objects remain objects);
--- malformed JSON yields an exact diagnostic.
---@param encoded string encoded arguments (JSON text)
---@return table|nil decoded
---@return string|nil err
function M.decode_encoded_args(encoded)
  if type(encoded) ~= "string" or encoded == "" then
    return nil, "tool arguments: empty encoded arguments"
  end
  local ok, decoded = pcall(vim.json.decode, encoded)
  if not ok or type(decoded) ~= "table" then
    return nil, ("tool arguments: invalid JSON: %s"):format(tostring(encoded):sub(1, 200))
  end
  return decoded, nil
end

return M
