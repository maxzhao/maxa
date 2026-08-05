-- filepath: lua/maxa/runtime/protocol/adapters/openai_chat.lua
--- maxa OpenAI Chat Completions adapter (phase-1 W4).
---
--- Implements the unified adapter interface (see lua/maxa/runtime/protocol/init.lua)
--- for the `openai_chat` protocol. It translates between the maxa normalized
--- message/event model and the OpenAI Chat Completions HTTP/SSE surface:
---
---   setup(self, opts) -> params | nil, err
---     Normalizes provider options (model/stream/base_url/api_key_env/timeouts).
---     Resets the per-request parsing context (fresh request identity).
---
---   build_request(self, params, normalized) -> body
---     normalized -> {model, messages, stream?, stream_options?, tools?}
---     - messages[]: role mapping (system|project -> system, user, assistant, tool),
---       text content as string, image parts as image_url data-URI content list,
---       assistant tool_calls as {id,type,function} only, tool results as
---       {role:"tool", tool_call_id, content} (one message per tool_result part).
---     - tools: sent only when non-empty (contract: absent/empty tools omit the field).
---     - stream=true adds `stream` + `stream_options.include_usage` (usage in the
---       final chunk); non-stream requests omit both keys (CodeCompanion alignment).
---
---   parse_stream(self, frame) -> event | event[] | nil
---     One SSE frame (as produced by maxa.runtime.protocol.sse) -> normalized events.
---     A frame may produce multiple events, so the return is an event or an event
---     LIST (additive extension of the documented single-event signature; the mock
---     and the fixture driver both accept either). `[DONE]` frames yield nil.
---     - choices[].delta.content -> message_delta
---     - delta.tool_calls[] keyed by protocol `index`: tool_call_started on first
---       fragment (synthetic `call_<created>_<index>` id when the provider omits
---       `id`, marked id_source="synthetic"), tool_args_delta per fragment
---       (UTF-8 appended byte-wise), tool_call_completed when finish_reason
---       arrives (all open calls, insertion order).
---     - finish_reason -> finish_reason event (after pending completions).
---     - body.usage -> usage_updated (provider_delta, final=false: the adapter
---       cannot know a chunk is the last one; the transport on_done marks the
---       stream terminal).
---     - malformed JSON -> a single terminal `error` event (code=protocol) and the
---       request context is terminalized (later frames are rejected).
---
---   parse_nonstream(self, body) -> event | event[] | nil
---     A full non-stream response body -> message_delta + tool_call events +
---     finish_reason + usage_updated (provider_final). HTTP-error bodies are NOT
---     parsed here: the transport/HTTP-status layer classifies them (fixture
---     driver mirrors that with transport.classify_error).
---
---   normalize_usage(self, raw, opts) -> usage
---     Delegates to maxa.runtime.protocol.normalize (OpenAI aliases:
---     prompt_tokens/completion_tokens/total_tokens + nested details).
---
---   stream(self, params, callbacks) -> handle | nil, err
---     Live transport path: plenary transport POST /chat/completions, feeds
---     chunks through sse.new() + parse_stream, flushes open tool calls via
---     finish_stream() at on_done, and forwards terminal errors via on_error.
---     Requires params.base_url and params.api_key_env (env var name); returns
---     nil + err when the request cannot start (missing base_url/key).
---     params.normalized = { messages=..., tools=... } supplies the request payload.
---
---   finish_stream(self) -> event[] | nil   (additive, end-of-stream finalization)
---     Emits tool_call_completed for any still-open tool calls (used by the
---     fixture driver and by stream() at transport on_done).
---
---   cancel(self) -> event | nil            (additive, frame-level cancel)
---     Marks the request context cancelled and returns the terminal `error`
---     (code=cancelled) event exactly once; all subsequent parse_stream calls
---     return nil (late events rejected).
---
--- Per-request state: the adapter keeps ONE active request context (self._reqctx),
--- created/reset by setup()/stream(). Concurrent streams are not supported by
--- this adapter; the orchestrator serializes requests.
---
--- Dependencies: maxa.runtime.protocol (registry), protocol.normalize, protocol.sse,
--- protocol.transport, maxa.runtime.schema. Never loads codecompanion.* / mcphub.* /
--- lua/util/hooks/*. Self-registers as "openai_chat" on module load.
--- Alignment (read-only) to pinned CodeCompanion v18.7.0 openai.lua
--- (form_messages/chat_output/tokens) and the official OpenAI Chat Completions
--- reference (wiki/protocols/openai-chat-completions.md).

local normalize = require("maxa.runtime.protocol.normalize")
local sse = require("maxa.runtime.protocol.sse")
local transport = require("maxa.runtime.protocol.transport")
local schema = require("maxa.runtime.schema")
local protocol = require("maxa.runtime.protocol")

local M = {}

M.name = "openai_chat"

--- Default model used when provider options do not declare one (phase-1 dev
--- default; real deployments resolve the model through config/runtime.yaml).
M.DEFAULT_MODEL = "deepseek-v4-flash"

--- Endpoint suffix (contract: "Target endpoint suffix: /chat/completions").
M.ENDPOINT = "/chat/completions"

--- Adapter instance (unified interface surface).
local adapter = {}

adapter.name = "openai_chat"
adapter.protocol = "openai_chat"
--- Capability declaration (provider-contract matrix): chat completions provides
--- vision (image_url content) and tools (function tools) as native channels;
--- reasoning is NOT a native channel for this protocol (no reasoning content
--- field in the pinned baseline).
adapter.capabilities = { vision = true, tools = true, reasoning = false }

--- New empty request context (tool accumulators + terminal flags).
---@return table ctx
local function new_ctx()
  return {
    tools = {}, -- index -> { id, name, synthetic, args=list<string> }
    tool_order = {}, -- insertion-ordered indices (deterministic completions)
    cancelled = false,
    terminal = nil, -- typed error once the request failed terminally
  }
end

--- Current request context (lazily created; setup()/stream() reset it).
---@return table ctx
function adapter:_ctx()
  if not self._reqctx then
    self._reqctx = new_ctx()
  end
  return self._reqctx
end

--- setup: normalize provider options and start a fresh request context.
---@param opts table provider_options from config/fixture
---@return table|nil params
---@return string|nil err
function adapter.setup(self, opts)
  opts = opts or {}
  if opts.model ~= nil and type(opts.model) ~= "string" then
    return nil, "openai_chat.setup: model must be a string"
  end
  if opts.stream ~= nil and type(opts.stream) ~= "boolean" then
    return nil, "openai_chat.setup: stream must be a boolean"
  end
  local params = {
    model = opts.model or M.DEFAULT_MODEL,
    stream = opts.stream ~= false,
    base_url = opts.base_url,
    api_key_env = opts.api_key_env,
    connect_timeout_ms = opts.connect_timeout_ms,
    timeout_ms = opts.timeout_ms,
    proxy_env = opts.proxy_env,
  }
  self._params = params
  self._reqctx = new_ctx()
  return params, nil
end

--- Normalized role -> OpenAI Chat role mapping. `project` (project-level rule
--- context) maps to `system`; `developer` is not used (not supported by all
--- phase-1 targets).
---@param role string normalized role
---@return string provider role
local function map_role(role)
  if role == "system" or role == "project" then
    return "system"
  end
  if role == "assistant" then
    return "assistant"
  end
  if role == "tool" then
    return "tool"
  end
  return "user"
end

--- build_request: normalized messages/tools -> provider request body.
---@param params table setup params
---@param normalized table { messages=table[], tools=table[] }
---@return table body
function adapter.build_request(self, params, normalized)
  normalized = normalized or {}
  local messages = {}
  for _, msg in ipairs(normalized.messages or {}) do
    local role = map_role(msg.role)
    local parts = type(msg.content) == "table" and msg.content or {}
    local text_parts, image_parts, tool_calls, tool_results = {}, {}, {}, {}
    for _, part in ipairs(parts) do
      if part.type == "text" then
        text_parts[#text_parts + 1] = part.text or ""
      elseif part.type == "image" then
        image_parts[#image_parts + 1] = part
      elseif part.type == "tool_call" then
        tool_calls[#tool_calls + 1] = part
      elseif part.type == "tool_result" then
        tool_results[#tool_results + 1] = part
      end
      -- reasoning parts: no reasoning channel in chat completions (skipped).
      -- context_ref parts: resolved by the conversation layer before the
      -- adapter; unresolved references are skipped here (never sent raw).
    end
    if role == "tool" then
      -- One provider message per tool_result part (tool_call_id pairs the call).
      for _, tr in ipairs(tool_results) do
        messages[#messages + 1] = {
          role = "tool",
          tool_call_id = tr.call_id,
          content = tr.content or "",
        }
      end
      -- A tool message without tool_result parts is malformed normalized input;
      -- nothing is emitted for it.
    else
      local entry = { role = role }
      if #image_parts > 0 then
        -- Mixed text+image content becomes a content-part list.
        local content = {}
        for _, t in ipairs(text_parts) do
          content[#content + 1] = { type = "text", text = t }
        end
        for _, img in ipairs(image_parts) do
          content[#content + 1] = {
            type = "image_url",
            image_url = { url = ("data:%s;base64,%s"):format(img.mime or "image/png", img.blob_ref or "") },
          }
        end
        entry.content = content
      else
        entry.content = table.concat(text_parts)
      end
      if role == "assistant" and #tool_calls > 0 then
        -- Contract: assistant tool calls carry ONLY id/type/function.
        entry.tool_calls = {}
        for _, tc in ipairs(tool_calls) do
          entry.tool_calls[#entry.tool_calls + 1] = {
            id = tc.call_id,
            type = "function",
            ["function"] = { name = tc.name, arguments = tc.arguments or "" },
          }
        end
      end
      messages[#messages + 1] = entry
    end
  end

  local body = { model = params.model, messages = messages }
  if params.stream then
    body.stream = true
    body.stream_options = { include_usage = true }
  end
  local tools = normalized.tools or {}
  if #tools > 0 then
    body.tools = tools
  end
  return body
end

--- Resolve the stable per-call identity for a streamed tool fragment.
--- A provider `id` is authoritative; when omitted a synthetic id is generated
--- (`call_<created>_<index>`) and the started event is marked id_source="synthetic".
---@param tool table raw tool fragment
---@param body table decoded chunk (for `created`)
---@param idx integer protocol tool index
---@return string id
---@return boolean synthetic
local function resolve_call_id(tool, body, idx)
  local id = tool.id
  if type(id) == "string" and id ~= "" then
    return id, false
  end
  local created = body.created
  return ("call_%s_%s"):format(tostring(type(created) == "number" and created or os.time()), tostring(idx)), true
end

--- Process one delta.tool_calls list into events (accumulate by index).
---@param ctx table request context
---@param body table decoded chunk
---@param tool_calls table raw delta.tool_calls list
---@param events table[] event accumulator
function adapter:_process_tool_calls(ctx, body, tool_calls, events)
  for i, tool in ipairs(tool_calls) do
    if type(tool) == "table" then
      local idx = tool.index
      if type(idx) ~= "number" then
        idx = i
      end
      local fn = tool["function"]
      local rec = ctx.tools[idx]
      if not rec then
        local id, synthetic = resolve_call_id(tool, body, idx)
        local name = (type(fn) == "table" and type(fn.name) == "string" and fn.name) or ""
        rec = { id = id, name = name, synthetic = synthetic, args = {} }
        ctx.tools[idx] = rec
        ctx.tool_order[#ctx.tool_order + 1] = idx
        local fields = synthetic and { id_source = "synthetic" } or nil
        events[#events + 1] = normalize.tool_call_started(id, name, fields)
      elseif type(fn) == "table" and type(fn.name) == "string" and fn.name ~= "" and rec.name == "" then
        -- A continuation fragment may carry the name when the first fragment
        -- omitted it; backfill without re-emitting started.
        rec.name = fn.name
      end
      if type(fn) == "table" and type(fn.arguments) == "string" and fn.arguments ~= "" then
        rec.args[#rec.args + 1] = fn.arguments
        events[#events + 1] = normalize.tool_args_delta(rec.id, fn.arguments)
      end
    end
  end
end

--- Complete all open tool calls (insertion order) as tool_call_completed events.
---@param ctx table request context
---@param events table[] event accumulator
function adapter:_complete_open_calls(ctx, events)
  local recs = {}
  for _, idx in ipairs(ctx.tool_order) do
    local rec = ctx.tools[idx]
    if rec then
      recs[#recs + 1] = rec
    end
  end
  ctx.tool_order = {}
  ctx.tools = {}
  for _, rec in ipairs(recs) do
    local encoded = table.concat(rec.args)
    local fields = { name = rec.name }
    if rec.synthetic then
      fields.id_source = "synthetic"
    end
    events[#events + 1] = normalize.tool_call_completed(rec.id, encoded, fields)
  end
end

--- parse_stream: one SSE frame -> normalized event(s).
---@param frame table|string SSE frame {data=...} or raw data string
---@return table|table[]|nil event, event list, or nil
function adapter.parse_stream(self, frame)
  local ctx = self:_ctx()
  if ctx.cancelled or ctx.terminal then
    return nil -- late frames after cancel/failure are rejected
  end
  if type(frame) == "table" and sse.is_done(frame) then
    return nil -- [DONE] is an end marker, not content
  end
  local data = type(frame) == "string" and frame or (frame and frame.data)
  if type(data) ~= "string" or data == "" then
    return nil
  end
  local ok, body = pcall(vim.json.decode, data, { luanil = { object = true } })
  if not ok or type(body) ~= "table" then
    local err = schema.new_error(
      schema.ERROR.PROTOCOL,
      ("openai_chat: malformed stream JSON: %s"):format(tostring(data):sub(1, 120)),
      { frame = tostring(data):sub(1, 200) },
      true
    )
    ctx.terminal = err
    return normalize.error(err)
  end

  local events = {}
  local choices = body.choices
  if type(choices) == "table" and #choices > 0 then
    local choice = choices[1]
    local delta = type(choice) == "table" and choice.delta
    if type(delta) == "table" then
      local content = delta.content
      if type(content) == "string" and content ~= "" then
        events[#events + 1] = normalize.message_delta(content)
      end
      -- Tool calls across choices (n=1 in practice; index keys the calls).
      for _, ch in ipairs(choices) do
        local d = type(ch) == "table" and ch.delta
        if type(d) == "table" and type(d.tool_calls) == "table" and #d.tool_calls > 0 then
          self:_process_tool_calls(ctx, body, d.tool_calls, events)
        end
      end
      local fr = type(choice) == "table" and choice.finish_reason
      if type(fr) == "string" and fr ~= "" then
        -- A typed finish_reason finalizes open tool calls (payload first, then
        -- the reason marker) and is never treated as completion by itself.
        self:_complete_open_calls(ctx, events)
        events[#events + 1] = normalize.finish_reason(fr)
      end
    end
  end
  -- Usage-only chunks (no choices) and usage-bearing chunks both update usage.
  if type(body.usage) == "table" and not vim.tbl_isempty(body.usage) then
    events[#events + 1] = normalize.usage_updated(self:normalize_usage(body.usage, { final = false }))
  end

  if #events == 0 then
    return nil
  end
  if #events == 1 then
    return events[1]
  end
  return events
end

--- parse_nonstream: full response body -> normalized event(s).
---@param body table decoded non-stream response
---@return table|table[]|nil event, event list, or nil
function adapter.parse_nonstream(self, body)
  local ctx = self:_ctx()
  if ctx.cancelled or ctx.terminal then
    return nil
  end
  if type(body) ~= "table" then
    local err =
      schema.new_error(schema.ERROR.PROTOCOL, "openai_chat: non-stream response body must be a table", nil, true)
    ctx.terminal = err
    return normalize.error(err)
  end
  local events = {}
  local choices = body.choices
  if type(choices) == "table" and #choices > 0 then
    local choice = choices[1]
    local msg = type(choice) == "table" and choice.message
    if type(msg) == "table" then
      if type(msg.content) == "string" and msg.content ~= "" then
        events[#events + 1] = normalize.message_delta(msg.content)
      end
      if type(msg.tool_calls) == "table" and #msg.tool_calls > 0 then
        for i, tool in ipairs(msg.tool_calls) do
          if type(tool) == "table" then
            local fn = tool["function"]
            local id, synthetic = resolve_call_id(tool, body, i)
            local name = (type(fn) == "table" and type(fn.name) == "string" and fn.name) or ""
            local args = (type(fn) == "table" and type(fn.arguments) == "string" and fn.arguments) or ""
            local fields = { name = name }
            if synthetic then
              fields.id_source = "synthetic"
            end
            events[#events + 1] =
              normalize.tool_call_started(id, name, synthetic and { id_source = "synthetic" } or nil)
            -- Non-stream calls arrive complete: started + completed (no deltas).
            events[#events + 1] = normalize.tool_call_completed(id, args, fields)
          end
        end
      end
      local fr = type(choice) == "table" and choice.finish_reason
      if type(fr) == "string" and fr ~= "" then
        events[#events + 1] = normalize.finish_reason(fr)
      end
    end
  end
  if type(body.usage) == "table" and not vim.tbl_isempty(body.usage) then
    events[#events + 1] = normalize.usage_updated(self:normalize_usage(body.usage, { final = true }))
  end
  if #events == 0 then
    return nil
  end
  if #events == 1 then
    return events[1]
  end
  return events
end

--- normalize_usage: provider usage object -> normalized snapshot.
---@param raw table|nil provider usage (OpenAI chat.completions shape)
---@param opts? table { final=bool, context_limit=integer|nil, updated_at=integer|nil }
---@return table usage
function adapter.normalize_usage(self, raw, opts)
  return normalize.normalize_usage(raw, opts)
end

--- finish_stream: end-of-stream finalization (flush open tool calls).
---@return table|nil events tool_call_completed event(s), or nil
function adapter.finish_stream(self)
  local ctx = self:_ctx()
  if ctx.cancelled or ctx.terminal then
    return nil
  end
  local events = {}
  self:_complete_open_calls(ctx, events)
  if #events == 0 then
    return nil
  end
  return events
end

--- cancel: terminal frame-level cancel (exactly one cancelled error event).
---@return table|nil event
function adapter.cancel(self)
  local ctx = self:_ctx()
  if ctx.cancelled or ctx.terminal then
    return nil
  end
  local err = schema.new_error(schema.ERROR.CANCELLED, "openai_chat: stream cancelled by caller", nil, true)
  ctx.cancelled = true
  ctx.terminal = err
  return normalize.error(err)
end

--- Flatten a parse_stream return (nil | event | event[]) into the callback.
---@param out table|table[]|nil parsed events
---@param on_event fun(event) callback
local function flush_events(out, on_event)
  if out == nil then
    return
  end
  if type(out) == "table" and out.type ~= nil then
    on_event(out)
  elseif type(out) == "table" then
    for _, ev in ipairs(out) do
      on_event(ev)
    end
  end
end

--- stream: live transport path (plenary curl via maxa transport).
---@param params table setup params (+ params.normalized = {messages, tools})
---@param callbacks table { on_event?, on_done?, on_error? }
---@return table|nil handle
---@return string|nil err when the request cannot start (missing base_url/key)
function adapter.stream(self, params, callbacks)
  callbacks = callbacks or {}
  params = params or self._params or {}
  local base = params.base_url
  if type(base) ~= "string" or base == "" then
    return nil, "openai_chat.stream: base_url required (config provider.base_url)"
  end
  local key = nil
  if type(params.api_key_env) == "string" and params.api_key_env ~= "" then
    key = os.getenv(params.api_key_env)
  end
  if type(key) ~= "string" or key == "" then
    return nil, ("openai_chat.stream: api key missing (env %q)"):format(tostring(params.api_key_env))
  end

  -- Fresh request context for this stream.
  self._reqctx = new_ctx()
  local body = self:build_request(params, params.normalized or {})
  local url = (base:gsub("/+$", "") .. M.ENDPOINT)
  local parser = sse.new()
  local finished = false

  local function on_frame(frame)
    local evs = self:parse_stream(frame)
    local function emit(ev)
      if finished then
        return
      end
      if callbacks.on_event then
        callbacks.on_event(ev)
      end
      if ev.type == normalize.events.error then
        -- Frame-level typed failure (malformed JSON etc.): terminal. The error
        -- is delivered as an event AND as the terminal on_error callback; every
        -- later chunk/frame is dropped.
        finished = true
        if callbacks.on_error then
          callbacks.on_error(ev.error)
        end
      end
    end
    flush_events(evs, emit)
  end

  local client = transport.new()
  local client_handle = client:post({
    url = url,
    headers = {
      ["Content-Type"] = "application/json",
      Authorization = "Bearer " .. key,
    },
    body = body,
    stream = params.stream ~= false,
    connect_timeout_ms = params.connect_timeout_ms,
    timeout_ms = params.timeout_ms,
    proxy_env = params.proxy_env,
  }, {
    on_chunk = function(data)
      if finished then
        return
      end
      for _, frame in ipairs(parser:feed(data)) do
        on_frame(frame)
      end
    end,
    on_done = function()
      if finished then
        return
      end
      for _, frame in ipairs(parser:finish()) do
        on_frame(frame)
      end
      flush_events(self:finish_stream(), function(ev)
        if callbacks.on_event then
          callbacks.on_event(ev)
        end
      end)
      finished = true
      if callbacks.on_done then
        callbacks.on_done()
      end
    end,
    on_error = function(err)
      if finished then
        return
      end
      finished = true
      if callbacks.on_error then
        callbacks.on_error(err)
      end
    end,
  })
  if not client_handle then
    return nil, "openai_chat.stream: transport.post failed to start"
  end

  return {
    id = client_handle.id,
    active = client_handle.active,
    cancel = function()
      return client_handle.cancel()
    end,
    status = function()
      return client_handle.status()
    end,
  }
end

-- Self-registration under the config protocol enum name.
protocol.register_adapter(adapter.protocol, adapter)

M.adapter = adapter

return M
