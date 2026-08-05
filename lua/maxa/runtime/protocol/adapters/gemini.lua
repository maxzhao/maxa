-- filepath: lua/maxa/runtime/protocol/adapters/gemini.lua
--- maxa runtime Gemini native protocol adapter (phase-1 W7).
---
--- Implements the unified adapter interface (see lua/maxa/runtime/protocol/init.lua)
--- for the `gemini` protocol, using the NATIVE Gemini API surface only:
---
---   non-stream: POST https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent
---   streaming:  POST .../models/{model}:streamGenerateContent   (SSE envelopes)
---
--- The pinned CodeCompanion baseline `adapters/http/gemini.lua` is an OpenAI
--- compatible implementation (uses /v1beta/openai/chat/completions) and is used
--- ONLY as negative evidence: this adapter NEVER uses OpenAI-compatible endpoints
--- or fields. Behavior is aligned to the official docs captured in
--- `.supermax/wiki/protocols/gemini-generate-content.md` (authority: official-source).
---
--- Request mapping (protocol-fixture-contract.md §"Gemini native API"):
---   - system/project messages -> text-only `systemInstruction.parts[]`
---   - user messages -> `contents[]` { role="user", parts[] }; assistant messages
---     -> { role="model", parts[] }; tool messages -> { role="user", parts=[functionResponse] }
---   - text parts -> { text }; image parts -> { inlineData { mimeType, data } }
---     (payload resolved from part.source.data or part.blob_ref; blob resolution is
---     the orchestrator's job, mirrors the anthropic adapter)
---   - assistant tool_call parts -> { functionCall { name, args (decoded object), id? } }
---     with provider_id forwarded as the native call id
---   - tool_result parts -> { functionResponse { name, id?, response { result } } };
---     the tool name is resolved from the paired earlier tool_call part (call_id map)
---   - normalized tools -> `tools[].functionDeclarations[]` ({ name, description?,
---     parameters? | parametersJsonSchema? }); empty tools omit the field
---   - generationConfig / safetySettings / toolConfig / cachedContent / serviceTier /
---     store are allowlisted provider options (never arbitrary passthrough)
---   - the model lives in the URL path, NOT the body (native GenerateContentRequest
---     has no top-level `model` field)
---
--- Streaming normalization (contract §"Response and streaming mapping"):
---   - each SSE envelope is processed independently (one data frame per envelope)
---   - `candidates[].content.parts[]`: text -> message_delta; functionCall ->
---     tool_call_started + tool_call_completed (Gemini calls arrive complete; a
---     missing functionCall id gets a synthetic stable id `gem-call-<n>` with
---     id_source="synthetic"); finishReason -> finish_reason (mapped label +
---     provider_reason + safety_ratings preserved)
---   - `usageMetadata` -> usage_updated (provider_final by default: Gemini reports
---     cumulative per-envelope usage); modality detail arrays and serviceTier are
---     preserved under usage.provider_metadata
---   - `promptFeedback.blockReason` (no candidates) -> typed terminal provider error
---   - a stream that ends without any candidate and without a block -> explicit
---     `empty-candidates` protocol outcome (finish_stream / parse_nonstream), never
---     silent success
---   - an `{"error":{code,status,message}}` envelope -> typed terminal error
---     (status mapped through transport.class_from_provider_type)
---   - malformed JSON / late envelopes after a terminal (error xor completed) or
---     after cancel are rejected by request identity
---
--- Adapter surface (unified interface; parse_stream/parse_nonstream return an
--- event, nil, or a LIST of events — additive extension like openai_chat/anthropic):
---   setup / build_request / parse_stream / parse_nonstream / normalize_usage /
---   stream / finish_stream (EOF finalization) / cancel (frame-level) / cancel_stream.
---
--- Dependencies: maxa.runtime.protocol, normalize, sse, transport, schema.
--- Never loads codecompanion.* / mcphub.* / lua/util/hooks/*.
--- Self-registers as "gemini" on module load.
local protocol = require("maxa.runtime.protocol")
local normalize = require("maxa.runtime.protocol.normalize")
local sse = require("maxa.runtime.protocol.sse")
local schema = require("maxa.runtime.schema")
local transport = require("maxa.runtime.protocol.transport")

local NAME = "gemini"
local DEFAULT_MODEL = "gemini-2.5-flash"
local DEFAULT_BASE_URL = "https://generativelanguage.googleapis.com/v1beta"
local DEFAULT_API_KEY_ENV = "GEMINI_API_KEY"

--- Monotonic request identity generator (late-frame rejection key).
local request_counter = 0
local function next_request_id()
  request_counter = request_counter + 1
  return ("gemini-%d-%d"):format(os.time(), request_counter)
end

--- Native finishReason enum -> normalized finish labels (unknown -> "other").
local M_FINISH_REASON = {
  STOP = "stop",
  MAX_TOKENS = "length",
  SAFETY = "safety",
  IMAGE_SAFETY = "safety",
  PROHIBITED_CONTENT = "safety",
  BLOCKLIST = "safety",
  RECITATION = "recitation",
  MALFORMED_FUNCTION_CALL = "tool_calls",
  OTHER = "other",
}

--- Allowlisted provider request options forwarded to the body verbatim.
local BODY_OPTIONS = {
  "generationConfig",
  "safetySettings",
  "toolConfig",
  "cachedContent",
  "serviceTier",
  "store",
}

--- usageMetadata modality detail fields preserved as provider metadata.
local META_KEYS = {
  promptTokensDetails = "prompt_tokens_details",
  candidatesTokensDetails = "candidates_tokens_details",
  cacheTokensDetails = "cache_tokens_details",
  toolUsePromptTokensDetails = "tool_use_prompt_tokens_details",
  thoughtsTokensDetails = "thoughts_tokens_details",
}

local adapter = {
  name = NAME,
  protocol = NAME,
  -- Capability declaration (provider-contract matrix): Gemini native provides
  -- vision (inlineData), tools (functionDeclarations) and reasoning
  -- (thoughtsTokenCount / thoughts parts) as native channels.
  capabilities = { vision = true, tools = true, reasoning = true },
}

--- Fresh per-request stream state (request identity + accumulators).
---@return table state
function adapter:_new_state()
  return {
    request_id = next_request_id(),
    started = false, -- response_started emitted once
    saw_candidate = false, -- at least one candidate envelope seen
    terminal = nil, -- typed error once the request failed terminally
    cancelled = false, -- caller cancelled: late frames rejected
    call_seq = 0, -- synthetic function-call id counter
  }
end

--- Current request state (lazily created; setup()/stream() reset it).
---@return table state
function adapter:_state()
  if not self._stream_state then
    self._stream_state = self:_new_state()
  end
  return self._stream_state
end

--- setup: normalize provider options and start a fresh request context.
---@param opts table provider_options from config/fixture
---@return table params
---@return nil err (setup is open-schema; type errors are surfaced by the config layer)
function adapter:setup(opts)
  opts = opts or {}
  local params = {
    model = opts.model or DEFAULT_MODEL,
    stream = opts.stream ~= false,
    base_url = opts.base_url or DEFAULT_BASE_URL,
    api_key_env = opts.api_key_env or DEFAULT_API_KEY_ENV,
  }
  for _, k in ipairs({
    "generationConfig",
    "safetySettings",
    "toolConfig",
    "cachedContent",
    "serviceTier",
    "store",
    "timeout_ms",
    "connect_timeout_ms",
    "proxy_env",
    "retries",
  }) do
    if opts[k] ~= nil then
      params[k] = opts[k]
    end
  end
  self._params = params
  self._stream_state = self:_new_state()
  return params, nil
end

--- Map one normalized content part to a native Gemini Part (nil when skipped).
---@param part table normalized content part
---@param call_names table<string,string> call_id -> tool name (tool_result pairing)
---@return table|nil part native Part
function adapter:_part_to_part(part, call_names)
  if type(part) ~= "table" then
    return nil
  end
  local ptype = part.type
  if ptype == "text" then
    return { text = part.text or "" }
  end
  if ptype == "image" then
    local data = type(part.source) == "table" and part.source.data or nil
    if type(data) ~= "string" or data == "" then
      data = part.blob_ref -- fixture/blob reference carried as the payload
    end
    if type(data) == "string" and data ~= "" then
      return { inlineData = { mimeType = part.mime or "image/png", data = data } }
    end
    return nil -- no resolvable payload: blob resolution is the orchestrator's job
  end
  if ptype == "tool_call" then
    local decoded, _ = normalize.decode_encoded_args(part.arguments)
    local fc = { name = part.name or "", args = decoded or {} }
    if type(part.provider_id) == "string" and part.provider_id ~= "" then
      fc.id = part.provider_id
    end
    call_names[part.call_id] = part.name
    return { functionCall = fc }
  end
  if ptype == "tool_result" then
    local name = call_names[part.call_id]
    if not name then
      return nil -- unpaired result: no function name to address; skip (never sent raw)
    end
    local response = { result = part.content or "" }
    if part.status == "error" or part.is_error == true then
      response.error = true -- normalized projection: Gemini has no native error flag
    end
    local fr = { name = name, response = response }
    if type(part.call_id) == "string" and part.call_id ~= "" then
      fr.id = part.call_id
    end
    return { functionResponse = fr }
  end
  -- reasoning parts: Gemini has no request-side reasoning channel (dropped).
  -- context_ref parts: must be resolved by the orchestrator before build_request
  -- (dropped here; never sent raw).
  return nil
end

--- Transform normalized tool schemas into native FunctionDeclarations.
---@param tools table[] normalized tools
---@return table[] declarations (empty list omits the body `tools` field)
function adapter:_build_tools(tools)
  local decls = {}
  for _, t in ipairs(tools or {}) do
    if type(t) == "table" and type(t.name) == "string" and t.name ~= "" then
      local decl = { name = t.name }
      if type(t.description) == "string" and t.description ~= "" then
        decl.description = t.description
      end
      if t.parameters ~= nil then
        decl.parameters = t.parameters
      elseif t.parametersJsonSchema ~= nil then
        decl.parametersJsonSchema = t.parametersJsonSchema
      end
      decls[#decls + 1] = decl
    end
  end
  return decls
end

--- Build the native GenerateContentRequest body (model stays in the URL path).
---@param params table setup params
---@param normalized table { messages=table[], tools=table[] }
---@return table body
function adapter:build_request(params, normalized)
  params = params or self._params or {}
  normalized = normalized or {}
  local system_parts = {}
  local contents = {}
  local call_names = {} -- call_id -> tool name (tool_result pairing)

  for _, msg in ipairs(normalized.messages or {}) do
    if msg.role == "system" or msg.role == "project" then
      -- systemInstruction is text-only (official docs): only text parts flow.
      for _, part in ipairs(msg.content or {}) do
        if part.type == "text" and type(part.text) == "string" and part.text ~= "" then
          system_parts[#system_parts + 1] = { text = part.text }
        end
      end
    else
      local role = msg.role == "assistant" and "model" or "user"
      local parts = {}
      for _, part in ipairs(msg.content or {}) do
        local gp = self:_part_to_part(part, call_names)
        if gp then
          parts[#parts + 1] = gp
        end
      end
      contents[#contents + 1] = { role = role, parts = parts }
    end
  end

  local body = {}
  if #system_parts > 0 then
    body.systemInstruction = { parts = system_parts }
  end
  if #contents > 0 then
    body.contents = contents
  end
  local decls = self:_build_tools(normalized.tools or {})
  if #decls > 0 then
    body.tools = { { functionDeclarations = decls } }
  end
  for _, k in ipairs(BODY_OPTIONS) do
    if params[k] ~= nil then
      body[k] = params[k]
    end
  end
  return body
end

--- form_tools: registry definitions -> Gemini functionDeclarations records
--- (W1 real path; consumed by `_build_tools` inside build_request). The
--- provider-facing call name is the registry id encoded for the wire
--- (`registry.provider_name`: `server-id/tool-name` -> `server-id-tool-name`;
--- Gemini function names only accept `^[a-zA-Z0-9_-]+$`) — unique per id, so
--- same-named tools from different servers never collide; execution resolves
--- the wire name back to the registry id through the orchestrator's
--- provider-name map. `parameters` is a per-provider schema copy (adaptation
--- never touches the definition).
---@param defs table[] registry:list() definitions
---@return table[] tools { { name, description, parameters }, ... }
function adapter:form_tools(defs)
  local registry_mod = require("maxa.runtime.tools.registry")
  local jschema = require("maxa.runtime.tools.schema")
  local out = {}
  for _, def in ipairs(defs or {}) do
    out[#out + 1] = {
      name = registry_mod.provider_name(def),
      description = def.description,
      parameters = jschema.copy(def.input_schema),
    }
  end
  return out
end

--- Emit the normalized events for one native functionCall part.
---@param fc table raw functionCall { id?, name, args }
---@param events table[] event accumulator
function adapter:_emit_function_call(fc, events)
  local state = self:_state()
  local id = (type(fc.id) == "string" and fc.id ~= "") and fc.id or nil
  local call_id = id
  local started_fields
  if not call_id then
    state.call_seq = state.call_seq + 1
    call_id = ("gem-call-%d"):format(state.call_seq)
    started_fields = { id_source = "synthetic" }
  end
  local name = (type(fc.name) == "string" and fc.name) or ""
  local encoded = vim.json.encode(type(fc.args) == "table" and fc.args or {})
  events[#events + 1] = normalize.tool_call_started(call_id, name, started_fields)
  events[#events + 1] = normalize.tool_call_completed(call_id, encoded, { name = name })
end

--- Process one decoded GenerateContentResponse envelope into normalized event(s).
--- A Gemini REST error envelope and a promptFeedback block are terminal.
---@param json table decoded envelope
---@return table|table[]|nil event(s)
function adapter:_process_envelope(json)
  local state = self:_state()
  if state.terminal or state.cancelled then
    return nil -- late envelopes after a terminal/cancel are rejected
  end

  -- Native REST error envelope: {"error":{code,status,message}}.
  if type(json) == "table" and type(json.error) == "table" then
    local err = json.error
    local status = type(err.status) == "string" and err.status or nil
    local class = transport.class_from_provider_type(status)
    local code = class and normalize.class_to_code(class) or schema.ERROR.PROVIDER
    local message = (type(err.message) == "string" and err.message ~= "") and err.message or "Gemini API error"
    local e = schema.new_error(code, message, { provider_type = status, code = err.code, status = status }, true)
    state.terminal = e
    return { normalize.error(e) }
  end

  -- Prompt blocked: no candidates + blockReason -> typed provider failure.
  local feedback = type(json) == "table" and json.promptFeedback or nil
  if type(feedback) == "table" and type(feedback.blockReason) == "string" and feedback.blockReason ~= "" then
    local e = schema.new_error(
      schema.ERROR.PROVIDER,
      ("Gemini prompt blocked (blockReason=%s)"):format(feedback.blockReason),
      { block_reason = feedback.blockReason, outcome = "prompt_blocked" },
      true
    )
    state.terminal = e
    return { normalize.error(e) }
  end

  local events = {}
  if not state.started then
    state.started = true
    events[#events + 1] = normalize.response_started({ request_id = state.request_id })
  end

  local candidates = type(json) == "table" and json.candidates or nil
  if type(candidates) == "table" and #candidates > 0 then
    state.saw_candidate = true
    for _, cand in ipairs(candidates) do
      if type(cand) == "table" then
        local content = cand.content
        if type(content) == "table" and type(content.parts) == "table" then
          for _, part in ipairs(content.parts) do
            if type(part) == "table" then
              if type(part.text) == "string" and part.text ~= "" then
                events[#events + 1] = normalize.message_delta(part.text)
              elseif type(part.functionCall) == "table" then
                self:_emit_function_call(part.functionCall, events)
              end
              -- inlineData/functionResponse parts are request-side members; a
              -- model response never carries them (skipped defensively).
            end
          end
        end
        local fr = cand.finishReason
        if type(fr) == "string" and fr ~= "" then
          local fields = { provider_reason = fr }
          if type(cand.safetyRatings) == "table" then
            fields.safety_ratings = cand.safetyRatings
          end
          events[#events + 1] = normalize.finish_reason(M_FINISH_REASON[fr] or "other", fields)
        end
      end
    end
  end

  if type(json) == "table" and type(json.usageMetadata) == "table" then
    local usage = self:normalize_usage(json.usageMetadata)
    if usage then
      events[#events + 1] = normalize.usage_updated(usage)
    end
  end

  if #events == 0 then
    return nil
  end
  if #events == 1 then
    return events[1]
  end
  return events
end

--- parse_stream: one SSE frame -> normalized event(s).
---@param frame table|string SSE frame {data=...} or raw data string
---@return table|table[]|nil event(s)
function adapter:parse_stream(frame)
  if type(frame) == "table" and sse.is_done(frame) then
    return nil -- [DONE] is an end marker, not content
  end
  local data = type(frame) == "string" and frame or (frame and frame.data)
  if type(data) ~= "string" or data == "" then
    return nil
  end
  local ok, json = pcall(vim.json.decode, data)
  if not ok or type(json) ~= "table" then
    local state = self:_state()
    local e = schema.new_error(
      schema.ERROR.PROTOCOL,
      ("gemini: malformed stream JSON: %s"):format(tostring(data):sub(1, 120)),
      { frame = tostring(data):sub(1, 200) },
      true
    )
    state.terminal = e
    return { normalize.error(e) }
  end
  return self:_process_envelope(json)
end

--- parse_nonstream: full response body -> normalized events.
---@param body table|string provider response body
---@return table[] events
function adapter:parse_nonstream(body)
  local json = body
  if type(body) == "string" then
    local ok, decoded = pcall(vim.json.decode, body)
    if not ok or type(decoded) ~= "table" then
      return {
        normalize.error(
          schema.new_error(
            schema.ERROR.PROTOCOL,
            "gemini: invalid non-stream response body",
            { body = tostring(body):sub(1, 200) },
            true
          )
        ),
      }
    end
    json = decoded
  end
  if type(json) ~= "table" then
    return {
      normalize.error(
        schema.new_error(schema.ERROR.PROTOCOL, "gemini: non-stream response must be a table", nil, true)
      ),
    }
  end

  self._stream_state = self:_new_state()
  local events = {}
  local out = self:_process_envelope(json)
  if out ~= nil then
    if out.type then
      events[#events + 1] = out
    else
      for _, e in ipairs(out) do
        events[#events + 1] = e
      end
    end
  end
  local state = self:_state()
  if not state.terminal and not state.cancelled then
    if not state.saw_candidate then
      -- Explicit empty-candidates outcome, not silent success.
      local e = schema.new_error(
        schema.ERROR.PROTOCOL,
        "Gemini returned no candidates (empty-candidates)",
        { outcome = "empty-candidates" },
        true
      )
      state.terminal = e
      events[#events + 1] = normalize.error(e)
    else
      events[#events + 1] = normalize.completed()
    end
  end
  return events
end

--- normalize_usage: Gemini usageMetadata -> normalized snapshot.
--- Provider fields are translated to the canonical aliases; modality detail
--- arrays and serviceTier are preserved as provider metadata.
---@param raw table|nil provider usageMetadata
---@param opts? table normalize options override (e.g. { final = false })
---@return table usage
function adapter:normalize_usage(raw, opts)
  opts = vim.tbl_deep_extend("force", { final = true }, opts or {})
  local translated = {}
  local function take(dst, src)
    local v = type(raw) == "table" and raw[src] or nil
    if type(v) == "number" then
      translated[dst] = v
    end
  end
  take("input_tokens", "promptTokenCount")
  take("output_tokens", "candidatesTokenCount")
  take("total_tokens", "totalTokenCount")
  -- normalize.normalize_usage reads cached input from `cache_read_input_tokens`
  -- (or nested prompt_tokens_details.cached_tokens); Gemini reports it as
  -- cachedContentTokenCount, so it is translated onto the alias it understands.
  take("cache_read_input_tokens", "cachedContentTokenCount")
  take("reasoning_tokens", "thoughtsTokenCount")
  take("tool_tokens", "toolUsePromptTokenCount")
  local usage = normalize.normalize_usage(translated, opts)
  if type(raw) == "table" then
    local meta = {}
    if raw.serviceTier ~= nil then
      meta.service_tier = raw.serviceTier
    end
    for src, dst in pairs(META_KEYS) do
      if type(raw[src]) == "table" then
        meta[dst] = raw[src]
      end
    end
    if not vim.tbl_isempty(meta) then
      usage.provider_metadata = meta
    end
  end
  return usage
end

--- finish_stream: end-of-stream finalization. A stream that ends without any
--- candidate (and without a block) is an explicit empty-candidates outcome.
---@return table|nil events empty-candidates error event, or nil
function adapter:finish_stream()
  local state = self:_state()
  if state.terminal or state.cancelled then
    return nil
  end
  if not state.saw_candidate then
    local e = schema.new_error(
      schema.ERROR.PROTOCOL,
      "Gemini stream ended without candidates (empty-candidates)",
      { outcome = "empty-candidates" },
      true
    )
    state.terminal = e
    return { normalize.error(e) }
  end
  return nil
end

--- Mark the current stream cancelled so late frames are rejected (internal
--- surface; invoked by the driver for cancel fixtures and by stream()).
function adapter:cancel_stream()
  local state = self:_state()
  if state then
    state.cancelled = true
  end
end

--- Frame-level cancel: terminal cancelled error event exactly once.
---@return table|nil event cancelled error event (nil when already terminal)
function adapter:cancel()
  local state = self:_state()
  if state.terminal or state.cancelled then
    return nil
  end
  local e = schema.new_error(schema.ERROR.CANCELLED, "gemini: stream cancelled by caller", nil, true)
  state.cancelled = true
  state.terminal = e
  return normalize.error(e)
end

--- Flatten a parse return (nil | event | event[]) into the callback.
---@param out table|table[]|nil parsed events
---@param emit fun(event) callback
local function flush_events(out, emit)
  if out == nil then
    return
  end
  if type(out) == "table" and out.type ~= nil then
    emit(out)
  elseif type(out) == "table" then
    for _, ev in ipairs(out) do
      emit(ev)
    end
  end
end

--- stream: live transport path (native generateContent endpoints).
--- params: { normalized|body, stream?, base_url?, api_key_env?, timeouts?, proxy_env? }
---@param params table stream request options
---@param callbacks table { on_event?=fun(event), on_done?=fun(), on_error?=fun(err) }
---@return table|nil handle
---@return string|nil err when the request cannot start (missing key)
function adapter:stream(params, callbacks)
  callbacks = callbacks or {}
  params = params or self._params or {}
  local base = params.base_url or DEFAULT_BASE_URL
  local model = params.model or DEFAULT_MODEL
  local api_key_env = params.api_key_env or DEFAULT_API_KEY_ENV
  local key = os.getenv(api_key_env)
  if type(key) ~= "string" or key == "" then
    return nil, ("gemini.stream: api key missing (env %q)"):format(api_key_env)
  end

  local stream_mode = params.stream ~= false
  local body = params.body or self:build_request(params, params.normalized or {})
  local url = (
    base:gsub("/+$", "")
    .. "/models/"
    .. model
    .. (stream_mode and ":streamGenerateContent" or ":generateContent")
  )

  self._stream_state = self:_new_state()
  local client = transport.new()
  local parser = sse.new()
  local done = false
  local terminal_error = nil

  local function deliver(out)
    local function emit(ev)
      if ev.type == "error" and not terminal_error then
        terminal_error = ev.error
      end
      if callbacks.on_event then
        callbacks.on_event(ev)
      end
    end
    flush_events(out, emit)
  end

  local handle = client:post({
    url = url,
    headers = { ["Content-Type"] = "application/json", ["x-goog-api-key"] = key },
    body = body,
    stream = stream_mode,
    timeout_ms = params.timeout_ms,
    connect_timeout_ms = params.connect_timeout_ms,
    proxy_env = params.proxy_env,
    retries = params.retries,
  }, {
    on_chunk = function(data)
      if not stream_mode or done then
        return
      end
      for _, frame in ipairs(parser:feed(data)) do
        deliver(self:parse_stream(frame))
      end
    end,
    on_done = function(response)
      if done then
        return
      end
      if stream_mode then
        for _, frame in ipairs(parser:finish()) do
          deliver(self:parse_stream(frame))
        end
        deliver(self:finish_stream())
      else
        deliver(self:parse_nonstream((response and response.body) or ""))
      end
      done = true
      if terminal_error then
        if callbacks.on_error then
          callbacks.on_error(terminal_error)
        end
      elseif callbacks.on_done then
        callbacks.on_done()
      end
    end,
    on_error = function(err)
      if done then
        return
      end
      done = true
      self:cancel_stream()
      if callbacks.on_error then
        callbacks.on_error(err)
      end
    end,
  })
  if not handle then
    return nil, "gemini.stream: transport.post failed to start"
  end

  local orig_cancel = handle.cancel
  handle.cancel = function(...)
    self:cancel_stream()
    return orig_cancel(...)
  end
  return handle
end

-- Register under the config protocol enum name (registry in protocol/init.lua).
protocol.register_adapter(NAME, adapter)

return adapter
