-- filepath: lua/maxa/runtime/protocol/adapters/openai_responses.lua
--- maxa OpenAI Responses adapter (phase-1 W6).
---
--- Implements the unified adapter interface (see lua/maxa/runtime/protocol/init.lua)
--- for the `openai_responses` protocol. It translates between the maxa normalized
--- message/event model and the OpenAI Responses HTTP/SSE surface:
---
---   setup(self, opts) -> params | nil, err
---     Normalizes provider options (model/stream/base_url/api_key_env/timeouts).
---
---   build_request(self, params, normalized) -> body
---     normalized -> {model, instructions?, input?, tools?, store, stream}
---     - system/project messages concatenate into `instructions` ("\n"-joined);
---       non-system records map to `input` items.
---     - user text parts -> {type:"message", role:"user", content=[input_text]}
---       with image parts as input_image data-URI items in the same content list.
---     - assistant text -> output_text content item; reasoning parts -> a
---       `reasoning` item with a summary_text summary (capability: reasoning);
---       assistant tool_call parts -> {type:"function_call", id, call_id, name,
---       arguments} (encoded JSON string preserved verbatim).
---     - tool-role tool_result parts -> {type:"function_call_output", call_id,
---       output} (paired by call id).
---     - function schemas pass recursive strict-mode normalization
---       (object -> additionalProperties=false + properties; empty properties
---       stays `{}` not `[]`; object keys sorted for deterministic output).
---     - `store=false` is always set (stateless mode; reasoning encrypted
---       content is not persisted by the provider).
---     - `stream=true` when the request is a stream (params.stream ~= false).
---
---   parse_stream(self, frame) -> event | event[] | nil
---     One SSE frame (as produced by maxa.runtime.protocol.sse, carrying the
---     `event:` line) -> normalized events. The event type comes from the
---     frame's `event:` field, falling back to the payload's `type` field
---     (compat with proxies that inline the type). A frame may produce
---     multiple events, so the return is an event or an event LIST.
---     - response.created establishes the response identity -> response_started
---     - response.output_text.delta -> message_delta
---     - response.reasoning_text.delta / reasoning_summary_text.delta -> reasoning_delta
---     - output_item.added records the item by output_index (no event)
---     - response.function_call_arguments.delta -> tool_call_started (first
---       fragment) + tool_args_delta (UTF-8 accumulated per call id)
---     - response.function_call_arguments.done -> tool_call_completed
---     - output_item.done (function_call, no arguments stream) ->
---       tool_call_started + tool_call_completed (tool-only responses are
---       valid and complete without any assistant text)
---     - response.completed -> any uncollected function_call items from
---       response.output[] + usage_updated (provider_final) + completed
---     - event:error / response.failed / response.incomplete -> typed terminal
---       error events that MUST win over any later EOF/exit callback; late
---       frames after a terminal (error xor completed) or after
---       `cancel_stream()` are rejected by request identity.
---
---   parse_nonstream(self, body) -> event | event[] | nil
---     A full non-stream response body ({object:"response", output, status,
---     usage}) -> response_started + output items + usage + terminal by status.
---
---   normalize_usage(self, raw, opts) -> usage
---     Delegates to maxa.runtime.protocol.normalize after translating the
---     Responses nested detail fields (input_tokens_details.cached_tokens ->
---     cache_read_input_tokens, output_tokens_details.reasoning_tokens ->
---     reasoning_tokens). Snapshots default to final=true (completed response).
---
---   stream(self, params, callbacks) -> handle | nil, err
---     Live transport path: POST /responses, feeds chunks through sse.new() +
---     parse_stream, forwards provider-frame errors as terminal on_error.
---     handle.cancel() also marks the stream cancelled so late frames are
---     rejected (frame-level invariant).
---
---   cancel_stream(self)                 (additive, driver/frame-level cancel)
---     Marks the current stream cancelled: all subsequent parse_stream calls
---     return nil (late events rejected).
---
--- Per-request state: one active stream state (self._stream_state) created by
--- response.created; the orchestrator serializes requests (no concurrent
--- streams, mirrors the other W4-W7 adapters).
---
--- Dependencies: maxa.runtime.protocol (registry), protocol.normalize,
--- protocol.sse, protocol.transport, maxa.runtime.schema. Never loads
--- codecompanion.* / mcphub.* / lua/util/hooks/*. Self-registers as
--- "openai_responses" on module load.
--- Alignment (read-only) to pinned CodeCompanion v18.7.0 openai_responses.lua
--- (build_messages/build_tools/parse_chat/parse_tokens) and the official
--- OpenAI Responses reference (wiki/protocols/openai-responses.md).

local normalize = require("maxa.runtime.protocol.normalize")
local sse = require("maxa.runtime.protocol.sse")
local transport = require("maxa.runtime.protocol.transport")
local schema = require("maxa.runtime.schema")
local protocol = require("maxa.runtime.protocol")

local NAME = "openai_responses"

--- Adapter instance (unified interface surface).
local adapter = {}

adapter.name = NAME
adapter.protocol = NAME
--- Capability declaration (provider-contract matrix): the Responses API
--- provides vision (input_image), tools (function_call items), and reasoning
--- (reasoning items / reasoning_summary deltas) as native channels.
adapter.capabilities = { vision = true, tools = true, reasoning = true }

--- Endpoint suffix (contract: "Target endpoint suffix: /responses").
adapter.ENDPOINT = "/responses"

--- Default model used when provider options do not declare one (phase-1 dev
--- default; real deployments resolve the model through config/runtime.yaml).
adapter.DEFAULT_MODEL = "deepseek-v4-flash"

--- Monotonic per-process request identity (stable within the process; the
--- fixture driver only asserts event type sequences, never this id).
local request_counter = 0
local function next_request_id()
  request_counter = request_counter + 1
  return ("resp-%s-%s"):format(os.time(), request_counter)
end

--- Fresh per-request stream state (request identity + tool item accumulators).
---@return table state
function adapter:_new_stream_state()
  return {
    request_id = next_request_id(),
    response_id = nil, -- response.created identity
    items = {}, -- output_index (0-based per protocol) -> item record
    terminal = false, -- error xor completed seen: late frames rejected
    cancelled = false, -- caller cancelled: late frames rejected
  }
end

----------------------------------------------------------------------------
-- setup
----------------------------------------------------------------------------

--- setup: normalize provider options. State is created lazily by the first
--- response.created frame (one stream per adapter instance).
---@param opts table provider_options from config/fixture
---@return table|nil params
---@return string|nil err
function adapter:setup(opts)
  opts = opts or {}
  if opts.model ~= nil and type(opts.model) ~= "string" then
    return nil, "openai_responses.setup: model must be a string"
  end
  if opts.stream ~= nil and type(opts.stream) ~= "boolean" then
    return nil, "openai_responses.setup: stream must be a boolean"
  end
  local params = {
    model = opts.model or adapter.DEFAULT_MODEL,
    stream = opts.stream ~= false,
    base_url = opts.base_url,
    api_key_env = opts.api_key_env,
    connect_timeout_ms = opts.connect_timeout_ms,
    timeout_ms = opts.timeout_ms,
    proxy_env = opts.proxy_env,
  }
  self._params = params
  return params, nil
end

----------------------------------------------------------------------------
-- Request building
----------------------------------------------------------------------------

--- Sorted key copy of a table (deterministic serialization for strict mode).
---@param t table
---@return table out
local function sorted_copy(t)
  local keys = vim.tbl_keys(t)
  table.sort(keys)
  local out = {}
  for _, k in ipairs(keys) do
    out[k] = t[k]
  end
  return out
end

--- Recursive strict-mode normalization of a function parameter schema
--- (OpenAI Responses strict mode): every object schema gets
--- `additionalProperties=false` and keeps an explicit (possibly empty)
--- `properties` object — an empty properties table must serialize as `{}`
--- and never as `[]`; object keys are sorted for deterministic output;
--- array schemas recurse into `items`; non-object nodes are copied verbatim.
---@param node any schema node
---@return any strictified node
local function strictify(node)
  if type(node) ~= "table" then
    return node
  end
  local out = sorted_copy(node)
  for _, k in ipairs(vim.tbl_keys(out)) do
    if type(out[k]) == "table" then
      out[k] = strictify(out[k])
    end
  end
  if node.type == "object" then
    out.additionalProperties = false
    local props = out.properties
    if props == nil or vim.tbl_isempty(props) then
      -- Empty object properties must serialize as `{}`, never as `[]`:
      -- vim.json.encode({}) yields `[]`, so the empty properties table is
      -- marked with vim.empty_dict() (encoded as an empty JSON object).
      out.properties = vim.empty_dict()
    end
  end
  return out
end

--- build_request: normalized messages/tools -> provider request body.
---@param params table setup params
---@param normalized table { messages=table[], tools=table[] }
---@return table body
function adapter:build_request(params, normalized)
  normalized = normalized or {}
  params = params or self._params or {}

  local body = { model = params.model }
  local instructions = {}
  local input = {}

  for _, msg in ipairs(normalized.messages or {}) do
    local parts = type(msg.content) == "table" and msg.content or {}
    local role = msg.role

    if role == "system" or role == "project" then
      -- System/project messages concatenate into instructions ("\n"-joined).
      for _, part in ipairs(parts) do
        if part.type == "text" then
          instructions[#instructions + 1] = part.text or ""
        end
      end
    elseif role == "tool" then
      -- Tool results map to function_call_output items (paired by call id).
      for _, part in ipairs(parts) do
        if part.type == "tool_result" then
          input[#input + 1] = {
            type = "function_call_output",
            call_id = part.call_id,
            output = part.content or "",
          }
        end
      end
    elseif role == "assistant" then
      -- Reasoning first (summary text), then the output_text message item,
      -- then one function_call item per tool_call part.
      local reasoning_item = nil
      local text_parts = {}
      local call_parts = {}
      for _, part in ipairs(parts) do
        if part.type == "reasoning" then
          reasoning_item = {
            type = "reasoning",
            summary = { { type = "summary_text", text = part.content or "" } },
          }
        elseif part.type == "text" then
          text_parts[#text_parts + 1] = part.text or ""
        elseif part.type == "tool_call" then
          call_parts[#call_parts + 1] = part
        end
        -- context_ref parts are resolved by the conversation layer before the
        -- adapter; unresolved references are skipped here (never sent raw).
      end
      if reasoning_item then
        input[#input + 1] = reasoning_item
      end
      if #text_parts > 0 then
        local content = {}
        for _, t in ipairs(text_parts) do
          content[#content + 1] = { type = "output_text", text = t }
        end
        input[#input + 1] = { type = "message", role = "assistant", content = content }
      end
      for _, tc in ipairs(call_parts) do
        input[#input + 1] = {
          type = "function_call",
          id = tc.call_id,
          call_id = tc.call_id,
          name = tc.name,
          arguments = tc.arguments or "",
        }
      end
    else
      -- user: text -> input_text, image -> input_image (data URI), shared list.
      local content = {}
      for _, part in ipairs(parts) do
        if part.type == "text" then
          content[#content + 1] = { type = "input_text", text = part.text or "" }
        elseif part.type == "image" then
          content[#content + 1] = {
            type = "input_image",
            image_url = ("data:%s;base64,%s"):format(part.mime or "image/png", part.blob_ref or ""),
          }
        end
      end
      if #content > 0 then
        input[#input + 1] = { type = "message", role = "user", content = content }
      end
    end
  end

  if #instructions > 0 then
    body.instructions = table.concat(instructions, "\n")
  end
  if #input > 0 then
    body.input = input
  end
  local tools = normalized.tools or {}
  if #tools > 0 then
    local strict_tools = {}
    for _, t in ipairs(tools) do
      strict_tools[#strict_tools + 1] = strictify(t)
    end
    body.tools = strict_tools
  end
  body.store = false
  if params.stream ~= false then
    body.stream = true
  end
  return body
end

----------------------------------------------------------------------------
-- Stream parsing
----------------------------------------------------------------------------

--- Stable call identity of a recorded function_call item: the provider
--- `call_id` (pairing key for function_call_output) wins; `id` is the fallback.
---@param rec table item record
---@return string|nil call_id
local function rec_call_id(rec)
  if type(rec.call_id) == "string" and rec.call_id ~= "" then
    return rec.call_id
  end
  if type(rec.id) == "string" and rec.id ~= "" then
    return rec.id
  end
  return nil
end

--- Locate the item record for a function_call event by output_index (preferred)
--- or item_id.
---@param json table decoded event payload
---@return table|nil rec
function adapter:_item_for(json)
  local state = self._stream_state
  if not state then
    return nil
  end
  local idx = json.output_index
  if type(idx) == "number" and state.items[idx] then
    return state.items[idx]
  end
  local iid = type(json.item_id) == "string" and json.item_id or nil
  if iid then
    for _, rec in pairs(state.items) do
      if rec.id == iid or rec.call_id == iid then
        return rec
      end
    end
  end
  return nil
end

--- Record a function_call item from an output_item payload (added/done frames).
---@param idx integer output_index
---@param item table output_item payload
---@return table rec
local function record_item(state, idx, item)
  local rec = state.items[idx] or {}
  rec.id = type(item.id) == "string" and item.id or rec.id
  rec.call_id = type(item.call_id) == "string" and item.call_id or rec.call_id
  rec.type = item.type
  rec.name = type(item.name) == "string" and item.name or rec.name
  rec.args = rec.args or {}
  rec.started = not not rec.started
  rec.completed = not not rec.completed
  state.items[idx] = rec
  return rec
end

--- Build the terminal typed error for a provider failure frame. Classifies the
--- provider error code through transport.class_from_provider_type when known;
--- unknown codes fall back to `fallback_code` (PROVIDER by default, never
--- guessed). A failed response means the provider side failed, so the caller
--- passes PROVIDER_UNAVAILABLE there (request-orchestrator error table);
--- transport-level event:error keeps the PROVIDER fallback.
---@param status string cause.status label ("failed"|"incomplete"|"error")
---@param ptype string|nil provider error code/type
---@param message string human-readable detail
---@param extra table extra cause fields
---@param fallback_code? string schema.ERROR.* code when the type is unknown
---@return table err typed terminal error
function adapter:_terminal_error(status, ptype, message, extra, fallback_code)
  local class = type(ptype) == "string" and transport.class_from_provider_type(ptype) or nil
  local code = class and normalize.class_to_code(class) or (fallback_code or schema.ERROR.PROVIDER)
  local cause = { status = status, provider_type = ptype, class = class }
  for k, v in pairs(extra or {}) do
    cause[k] = v
  end
  return schema.new_error(code, message, cause, true)
end

--- Complete one function_call item as normalized started+completed events.
---@param rec table item record
---@param args string encoded arguments (JSON text)
---@param events table[] event accumulator
function adapter:_complete_call(rec, args, events)
  local cid = rec_call_id(rec)
  if not cid then
    return
  end
  if args == "" then
    args = "{}"
  end
  if not rec.started then
    rec.started = true
    events[#events + 1] = normalize.tool_call_started(cid, rec.name or "")
  end
  rec.completed = true
  events[#events + 1] = normalize.tool_call_completed(cid, args, { name = rec.name or "" })
end

--- Process one decoded Responses event into normalized event(s).
---@param json table|nil decoded frame payload
---@param etype string event type (frame `event:` field or payload `type`)
---@return table|table[]|nil event(s)
function adapter:_process_frame(json, etype)
  if type(etype) ~= "string" or etype == "" then
    return nil
  end
  if type(json) ~= "table" then
    return nil
  end

  -- response.created establishes the response identity and resets all state.
  if etype == "response.created" then
    local state = self:_new_stream_state()
    state.response_id = type(json.id) == "string" and json.id or nil
    self._stream_state = state
    return { normalize.response_started({ request_id = state.request_id, role = "assistant" }) }
  end

  local state = self._stream_state
  -- Late frames after a terminal (error xor completed) or after cancel are
  -- rejected by request identity (no normalized events leak through).
  if not state or state.terminal or state.cancelled then
    return nil
  end

  if etype == "response.output_text.delta" then
    return { normalize.message_delta(json.delta or "") }
  end

  -- W10: real deepseek /responses emits `response.reasoning_text.delta` (full
  -- reasoning text; the captured live fixture has 23 such events); OpenAI-style
  -- `reasoning_summary_text.delta` is the summary variant. Both surface as
  -- reasoning_delta so the host renders the same `[reasoning N chars]` fold.
  if etype == "response.reasoning_text.delta" or etype == "response.reasoning_summary_text.delta" then
    return { normalize.reasoning_delta(json.delta or "") }
  end

  if etype == "response.output_item.added" then
    local item = type(json.output_item) == "table" and json.output_item or {}
    if type(json.output_index) == "number" then
      record_item(state, json.output_index, item)
    end
    return nil
  end

  if etype == "response.function_call_arguments.delta" then
    local rec = self:_item_for(json)
    if not rec then
      return nil
    end
    local events = {}
    local cid = rec_call_id(rec)
    if not cid then
      return nil
    end
    if not rec.started then
      rec.started = true
      events[#events + 1] = normalize.tool_call_started(cid, rec.name or "")
    end
    local fragment = json.delta or ""
    if fragment ~= "" then
      rec.args[#rec.args + 1] = fragment
      events[#events + 1] = normalize.tool_args_delta(cid, fragment)
    end
    if #events == 0 then
      return nil
    end
    return events
  end

  if etype == "response.function_call_arguments.done" then
    local rec = self:_item_for(json)
    if not rec then
      return nil
    end
    local args = type(json.arguments) == "string" and json.arguments or table.concat(rec.args)
    local events = {}
    self:_complete_call(rec, args, events)
    if #events == 0 then
      return nil
    end
    return events
  end

  if etype == "response.output_item.done" then
    local item = type(json.output_item) == "table" and json.output_item or {}
    local rec = self:_item_for(json)
    if type(json.output_index) == "number" and item.type == "function_call" then
      if not rec then
        rec = record_item(state, json.output_index, item)
      end
      if rec and not rec.completed then
        local args = type(item.arguments) == "string" and item.arguments or table.concat(rec.args)
        local events = {}
        self:_complete_call(rec, args, events)
        if #events > 0 then
          return events
        end
      end
    end
    return nil
  end

  if etype == "response.completed" then
    local events = {}
    local resp = type(json.response) == "table" and json.response or {}
    -- Function calls that never streamed arguments are still collected from
    -- response.output[] (tool-only responses are valid completions).
    if type(resp.output) == "table" then
      for i, out in ipairs(resp.output) do
        if type(out) == "table" and out.type == "function_call" then
          local idx = i - 1 -- output_index is 0-based
          local rec = state.items[idx]
          if not rec then
            rec = record_item(state, idx, out)
          end
          if not rec.completed then
            local args = type(out.arguments) == "string" and out.arguments or table.concat(rec.args)
            self:_complete_call(rec, args, events)
          end
        end
      end
    end
    if type(resp.usage) == "table" then
      events[#events + 1] = normalize.usage_updated(self:normalize_usage(resp.usage))
    end
    state.terminal = true
    events[#events + 1] = normalize.completed()
    return events
  end

  if etype == "response.failed" then
    local resp = type(json.response) == "table" and json.response or {}
    local err = type(resp.error) == "table" and resp.error or {}
    local ptype = type(err.code) == "string" and err.code or nil
    local message = (type(err.message) == "string" and err.message ~= "") and err.message
      or "OpenAI Responses provider failure"
    state.terminal = true
    return {
      normalize.error(
        self:_terminal_error(
          "failed",
          ptype,
          message,
          { response_id = state.response_id },
          schema.ERROR.PROVIDER_UNAVAILABLE
        )
      ),
    }
  end

  if etype == "response.incomplete" then
    local resp = type(json.response) == "table" and json.response or {}
    local details = type(resp.incomplete_details) == "table" and resp.incomplete_details or nil
    state.terminal = true
    return {
      normalize.error(
        schema.new_error(
          schema.ERROR.PROVIDER,
          "OpenAI Responses response incomplete",
          { status = "incomplete", incomplete_details = details, response_id = state.response_id },
          true
        )
      ),
    }
  end

  if etype == "error" then
    local ptype = type(json.code) == "string" and json.code or nil
    local message = (type(json.message) == "string" and json.message ~= "") and json.message
      or "OpenAI Responses stream error"
    state.terminal = true
    return {
      normalize.error(self:_terminal_error("error", ptype, message, {
        request_id = type(json.request_id) == "string" and json.request_id or nil,
      })),
    }
  end

  -- response.in_progress, output_text.done, content_part events, ping etc.
  -- produce no normalized content.
  return nil
end

--- Parse one stream frame into normalized event(s) (unified adapter
--- `parse_stream`). Accepts an sse frame table ({data=..., event=...}), an
--- already-decoded event object, or raw text (SSE text or JSON).
---@param frame any raw chunk, sse frame, or decoded event object
---@return table|table[]|nil normalized event(s)
function adapter:parse_stream(frame)
  if type(frame) == "table" and type(frame.type) == "string" then
    return self:_process_frame(frame, frame.type)
  end
  if type(frame) == "table" and (type(frame.data) == "string" or type(frame.event) == "string") then
    local etype = (type(frame.event) == "string" and frame.event ~= "") and frame.event or nil
    local data = type(frame.data) == "string" and frame.data or nil
    local json = nil
    if data ~= nil and data ~= "" then
      local ok, decoded = pcall(vim.json.decode, data)
      if ok and type(decoded) == "table" then
        json = decoded
      end
    end
    return self:_process_frame(json, etype or (json and json.type) or nil)
  end
  if type(frame) == "string" then
    -- Raw SSE text (event:/data: lines) or a bare JSON payload.
    local ok, json = pcall(vim.json.decode, frame)
    if ok and type(json) == "table" then
      return self:_process_frame(json, json.type)
    end
    local out = {}
    for _, f in ipairs(sse.parse(frame)) do
      local ev = self:parse_stream(f)
      if ev ~= nil then
        if ev.type then
          out[#out + 1] = ev
        else
          for _, e in ipairs(ev) do
            out[#out + 1] = e
          end
        end
      end
    end
    if #out == 1 then
      return out[1]
    end
    if #out == 0 then
      return nil
    end
    return out
  end
  return nil
end

----------------------------------------------------------------------------
-- Non-stream parsing
----------------------------------------------------------------------------

--- Parse a non-stream response body into normalized events (unified adapter
--- `parse_nonstream`). Accepts a table body or raw JSON text; output items
--- follow the same normalized output path as the streamed events.
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
            "openai_responses: invalid non-stream response body",
            { body = tostring(body):sub(1, 200) },
            true
          )
        ),
      }
    end
    json = decoded
  end
  if type(json) ~= "table" or json.object ~= "response" then
    return {
      normalize.error(
        schema.new_error(
          schema.ERROR.PROTOCOL,
          "openai_responses: unexpected non-stream response shape",
          { object = type(json) == "table" and json.object or nil },
          true
        )
      ),
    }
  end

  local events = {
    normalize.response_started({ request_id = next_request_id(), role = "assistant" }),
  }
  for _, item in ipairs(type(json.output) == "table" and json.output or {}) do
    if type(item) == "table" then
      local itype = item.type
      if itype == "message" then
        for _, block in ipairs(type(item.content) == "table" and item.content or {}) do
          if type(block) == "table" and block.type == "output_text" then
            events[#events + 1] = normalize.message_delta(block.text or "")
          end
        end
      elseif itype == "reasoning" then
        for _, block in ipairs(type(item.summary) == "table" and item.summary or {}) do
          if type(block) == "table" and block.type == "summary_text" then
            events[#events + 1] = normalize.reasoning_delta(block.text or "")
          end
        end
      elseif itype == "function_call" then
        local cid = (type(item.call_id) == "string" and item.call_id ~= "") and item.call_id
          or (type(item.id) == "string" and item.id or nil)
        if cid then
          local args = type(item.arguments) == "string" and item.arguments or ""
          if args == "" then
            args = "{}"
          end
          events[#events + 1] = normalize.tool_call_started(cid, item.name or "")
          events[#events + 1] = normalize.tool_call_completed(cid, args, { name = item.name or "" })
        end
      end
    end
  end
  if type(json.usage) == "table" then
    events[#events + 1] = normalize.usage_updated(self:normalize_usage(json.usage))
  end
  local status = json.status
  if status == "failed" then
    local err = type(json.error) == "table" and json.error or {}
    local ptype = type(err.code) == "string" and err.code or nil
    events[#events + 1] = normalize.error(
      self:_terminal_error(
        "failed",
        ptype,
        type(err.message) == "string" and err.message or "OpenAI Responses provider failure",
        {
          response_id = type(json.id) == "string" and json.id or nil,
        }
      )
    )
  elseif status == "incomplete" then
    events[#events + 1] = normalize.error(
      schema.new_error(
        schema.ERROR.PROVIDER,
        "OpenAI Responses response incomplete",
        { status = "incomplete", response_id = type(json.id) == "string" and json.id or nil },
        true
      )
    )
  else
    events[#events + 1] = normalize.completed()
  end
  return events
end

----------------------------------------------------------------------------
-- Usage normalization
----------------------------------------------------------------------------

--- Normalize a provider usage object into the schema.usage snapshot (unified
--- adapter `normalize_usage`). Responses reports usage on the completed
--- response, so snapshots default to `final=true`; the nested detail fields
--- (input_tokens_details.cached_tokens / output_tokens_details.reasoning_tokens)
--- are translated to the normalized aliases before delegating.
---@param raw table|nil provider usage object
---@param opts? table normalize options override (e.g. { final = false })
---@return table usage normalized snapshot
function adapter:normalize_usage(raw, opts)
  opts = vim.tbl_deep_extend("force", { final = true }, opts or {})
  local r = raw
  if type(raw) == "table" then
    r = vim.deepcopy(raw)
    local input_details = r.input_tokens_details
    if
      type(input_details) == "table"
      and type(input_details.cached_tokens) == "number"
      and r.cache_read_input_tokens == nil
    then
      r.cache_read_input_tokens = input_details.cached_tokens
    end
    local output_details = r.output_tokens_details
    if
      type(output_details) == "table"
      and type(output_details.reasoning_tokens) == "number"
      and r.reasoning_tokens == nil
    then
      r.reasoning_tokens = output_details.reasoning_tokens
    end
  end
  return normalize.normalize_usage(r, opts)
end

----------------------------------------------------------------------------
-- Cancel / live stream
----------------------------------------------------------------------------

--- Mark the current stream cancelled so late frames are rejected (internal
--- surface; also invoked by the driver for cancel fixtures and by stream()).
function adapter:cancel_stream()
  local state = self._stream_state
  if state then
    state.cancelled = true
  end
end

--- Drive a real HTTP stream over the unified callback object (unified adapter
--- `stream`). params: { base_url, api_key_env, normalized|body, stream?,
--- timeout_ms?, connect_timeout_ms?, proxy_env?, retries? }. Chunks are fed
--- through the SSE parser and parse_stream; a provider error frame
--- terminalizes via on_error.
---@param params table stream request options
---@param callbacks table { on_event?=fun(event), on_done?=fun(), on_error?=fun(err) }
---@return table handle transport handle (cancel wired to cancel_stream)
function adapter:stream(params, callbacks)
  callbacks = callbacks or {}
  params = params or self._params or {}
  local body = params.body
  if body == nil then
    body = self:build_request(params, params.normalized or {})
  end
  local base = params.base_url
  local url = params.url or (type(base) == "string" and base ~= "" and base:gsub("/+$", "") .. adapter.ENDPOINT) or nil
  if type(url) ~= "string" or url == "" then
    return nil, "openai_responses.stream: base_url required (config provider.base_url)"
  end
  local key = nil
  if type(params.api_key_env) == "string" and params.api_key_env ~= "" then
    key = os.getenv(params.api_key_env)
  end
  if type(key) ~= "string" or key == "" then
    return nil, ("openai_responses.stream: api key missing (env %q)"):format(tostring(params.api_key_env))
  end

  local client = transport.new()
  local parser = sse.new()
  local done = false
  local terminal_error = nil

  local function deliver(ev)
    if ev == nil or done then
      return
    end
    local function emit(e)
      if e.type == "error" and not terminal_error then
        terminal_error = e.error
      end
      if callbacks.on_event then
        callbacks.on_event(e)
      end
    end
    if ev.type then
      emit(ev)
    else
      for _, e in ipairs(ev) do
        emit(e)
      end
    end
  end

  local handle = client:post({
    url = url,
    headers = {
      ["Content-Type"] = "application/json",
      Authorization = "Bearer " .. key,
    },
    body = body,
    stream = params.stream ~= false,
    timeout_ms = params.timeout_ms,
    connect_timeout_ms = params.connect_timeout_ms,
    proxy_env = params.proxy_env,
    retries = params.retries,
  }, {
    on_chunk = function(data)
      for _, frame in ipairs(parser:feed(data)) do
        deliver(self:parse_stream(frame))
      end
    end,
    on_done = function()
      for _, frame in ipairs(parser:finish()) do
        deliver(self:parse_stream(frame))
      end
      if done then
        return
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
    return nil, "openai_responses.stream: transport.post failed to start"
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
