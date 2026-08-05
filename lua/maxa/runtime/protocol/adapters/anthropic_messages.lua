-- filepath: lua/maxa/runtime/protocol/adapters/anthropic_messages.lua
--- maxa runtime Anthropic Messages protocol adapter (phase-1 W5).
---
--- Implements the unified adapter interface (protocol/init.lua §4.1) for the
--- Anthropic Messages API (POST /v1/messages), aligned (read-only) to the pinned
--- CodeCompanion v18.7.0 baseline `anthropic.lua` (form_messages / chat_output /
--- tokens) and validated against the official SDK reference captured in
--- `.supermax/wiki/protocols/anthropic-messages.md`. The upstream module is
--- NEVER imported; only behavior is aligned.
---
--- Request mapping (contract §"Anthropic Messages / Request mapping"):
---   - system/project messages -> `system` text blocks, removed from `messages`
---   - user/assistant content parts -> text blocks; empty user continuation maps
---     to the configured nonempty placeholder (`params.placeholder`)
---   - assistant tool_call parts -> `tool_use` blocks with decoded object input
---   - tool_result parts (tool role) -> user-role `tool_result` blocks
---   - consecutive same-role messages merge; adjacent tool_result blocks with the
---     same tool_use_id consolidate their content without losing call identity
---   - reasoning parts -> `thinking` blocks with signature only when the
---     configured capability requires round-trip retention
---   - image parts -> base64 source blocks only when vision is enabled; the
---     adapter never resolves blob references (the orchestrator attaches
---     `part.source.data` before calling build_request)
---
--- Streaming normalization (contract §"Streaming normalization"):
---   - message_start -> response_started (role + initial usage held in state)
---   - content_block_start (tool_use) -> tool_call_started by block index
---   - content_block_delta -> message_delta / reasoning_delta / tool_args_delta
---     (partial_json accumulated by block index; signature flows through a
---     reasoning_delta with empty delta + signature field)
---   - content_block_stop (tool_use) -> tool_call_completed with the accumulated
---     encoded arguments (empty input normalizes to "{}")
---   - message_delta -> finish_reason (stop_reason) + usage_updated (combined
---     initial input usage + delta output usage; cache fields not double counted)
---   - message_stop -> completed; ping frames are ignored
---   - an `error` frame is a typed terminal error (provider class mapping);
---     frames arriving after a terminal (error xor completed) or after
---     `cancel_stream()` are rejected by request identity (plan §4.1 invariant)
---
--- parse_stream returns a single normalized event, nil, or a LIST of events
--- (one Anthropic frame can produce multiple normalized events, e.g.
--- message_delta -> finish_reason + usage_updated). Consumers (the fixture
--- driver and stream()) flatten lists.
---
--- Dependencies: maxa.runtime.protocol, normalize, sse, transport, schema.
--- Never loads codecompanion.* / mcphub.* / lua/util/hooks/*.
local protocol = require("maxa.runtime.protocol")
local normalize = require("maxa.runtime.protocol.normalize")
local sse = require("maxa.runtime.protocol.sse")
local schema = require("maxa.runtime.schema")
local transport = require("maxa.runtime.protocol.transport")

local NAME = "anthropic_messages"
local DEFAULT_URL = "https://api.anthropic.com/v1/messages"
local DEFAULT_MODEL = "claude-sonnet-4-6"
local DEFAULT_MAX_TOKENS = 4096
local DEFAULT_PLACEHOLDER = "<prompt></prompt>"

--- Monotonic request identity generator (per-process; late-frame rejection key).
local request_counter = 0
local function next_request_id()
  request_counter = request_counter + 1
  return ("anthropic-%d-%d"):format(os.time(), request_counter)
end

local adapter = {
  name = NAME,
  protocol = NAME,
  -- Capability declaration (config capability-matrix validation in W3).
  capabilities = { vision = true, tools = true, reasoning = true },
}

--- Normalize caller-supplied provider options into setup params (unified
--- adapter `setup`). Unknown keys are ignored (open schema, like mock/echo).
---@param opts table caller-supplied options
---@return table params normalized setup params
function adapter:setup(opts)
  opts = opts or {}
  local params = {
    model = opts.model or DEFAULT_MODEL,
    max_tokens = opts.max_tokens or DEFAULT_MAX_TOKENS,
    stream = opts.stream ~= false,
    base_url = opts.base_url or DEFAULT_URL,
    api_key_env = opts.api_key_env or "ANTHROPIC_API_KEY",
    placeholder = opts.placeholder or DEFAULT_PLACEHOLDER,
    vision = opts.vision ~= false,
    retain_thinking = opts.retain_thinking ~= false,
  }
  for _, k in ipairs({
    "temperature",
    "top_p",
    "top_k",
    "stop_sequences",
    "thinking_budget",
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
  return params, nil
end

--- Build the provider request body from normalized parts (unified adapter
--- `build_request`). See the module header for the mapping rules.
---@param params table setup params (model/max_tokens/stream/placeholder/...)
---@param normalized table { messages=table[], tools=table[] }
---@return table body provider request body
function adapter:build_request(params, normalized)
  params = params or self._params or {}
  normalized = normalized or {}
  local system = {}
  local messages = {}
  for _, msg in ipairs(normalized.messages or {}) do
    if msg.role == "system" or msg.role == "project" then
      for _, part in ipairs(msg.content or {}) do
        if part.type == "text" and type(part.text) == "string" and part.text ~= "" then
          system[#system + 1] = { type = "text", text = part.text }
        end
      end
    else
      messages[#messages + 1] = self:_to_anthropic_message(msg, params)
    end
  end
  messages = self:_merge_same_role(messages)

  local body = {
    model = params.model or DEFAULT_MODEL,
    max_tokens = params.max_tokens or DEFAULT_MAX_TOKENS,
    stream = params.stream ~= false,
  }
  if #system > 0 then
    body.system = system
  end
  if #messages > 0 then
    body.messages = messages
  end
  if params.temperature ~= nil then
    body.temperature = params.temperature
  end
  if params.top_p ~= nil then
    body.top_p = params.top_p
  end
  if params.top_k ~= nil then
    body.top_k = params.top_k
  end
  if params.stop_sequences ~= nil then
    body.stop_sequences = params.stop_sequences
  end
  if params.thinking_budget ~= nil then
    body.thinking = { type = "enabled", budget_tokens = params.thinking_budget }
  end
  local tools = self:_build_tools(normalized.tools)
  if #tools > 0 then
    body.tools = tools
  end
  return body
end

--- Map one normalized message to an Anthropic message (role + content blocks).
---@param msg table normalized message (role/content parts)
---@param params table setup params
---@return table anthropic_message { role, content = table[] }
function adapter:_to_anthropic_message(msg, params)
  local role = msg.role == "tool" and "user" or msg.role
  local blocks = {}
  for _, part in ipairs(msg.content or {}) do
    local block = self:_part_to_block(part, role, params)
    if block then
      blocks[#blocks + 1] = block
    end
  end
  -- Anthropic rejects empty user prompts; the configured placeholder substitutes
  -- for empty user continuations (e.g. tool-result continuation turns).
  if #blocks == 0 and role == "user" then
    blocks[#blocks + 1] = { type = "text", text = params.placeholder or DEFAULT_PLACEHOLDER }
  end
  return { role = role, content = blocks }
end

--- Map one content part to an Anthropic content block (nil when skipped).
---@param part table normalized content part
---@param role string mapped role ("user"|"assistant")
---@param params table setup params
---@return table|nil block
function adapter:_part_to_block(part, role, params)
  if type(part) ~= "table" then
    return nil
  end
  local ptype = part.type
  if ptype == "text" then
    return { type = "text", text = part.text or "" }
  end
  if ptype == "tool_result" and role == "user" then
    return {
      type = "tool_result",
      tool_use_id = part.call_id,
      content = part.content or "",
      is_error = part.status == "error" or part.is_error == true,
    }
  end
  if ptype == "image" and role == "user" and params.vision ~= false then
    local data = type(part.source) == "table" and part.source.data or nil
    if type(data) == "string" and data ~= "" then
      return {
        type = "image",
        source = { type = "base64", media_type = part.mime, data = data },
      }
    end
    return nil -- no resolvable payload: blob resolution is the orchestrator's job
  end
  if ptype == "reasoning" and role == "assistant" and params.retain_thinking ~= false then
    local block = { type = "thinking", thinking = part.content or "" }
    if type(part.signature) == "string" and part.signature ~= "" then
      block.signature = part.signature
    end
    return block
  end
  if ptype == "tool_call" and role == "assistant" then
    local decoded, _ = normalize.decode_encoded_args(part.arguments)
    return {
      type = "tool_use",
      id = part.provider_id or part.call_id,
      name = part.name,
      input = decoded or {}, -- malformed history args degrade to {} at the boundary
    }
  end
  -- context_ref and other parts are skipped: refs must be resolved by the
  -- orchestrator into provider-visible content before build_request.
  return nil
end

--- Merge consecutive messages with the same role and consolidate adjacent
--- tool_result blocks with the same tool_use_id (identity preserved).
---@param messages table[] mapped Anthropic messages
---@return table[] merged
function adapter:_merge_same_role(messages)
  local merged = {}
  for _, m in ipairs(messages) do
    local prev = merged[#merged]
    if prev and prev.role == m.role then
      for _, block in ipairs(m.content) do
        prev.content[#prev.content + 1] = block
      end
      prev.content = self:_consolidate_tool_results(prev.content)
    else
      if m.role == "user" then
        m.content = self:_consolidate_tool_results(m.content)
      end
      merged[#merged + 1] = m
    end
  end
  return merged
end

--- Consolidate adjacent tool_result blocks with the same tool_use_id by
--- concatenating their content (aligned to CodeCompanion merge behavior).
---@param content table[] content blocks
---@return table[] consolidated
function adapter:_consolidate_tool_results(content)
  local out = {}
  for _, block in ipairs(content) do
    local prev = out[#out]
    if
      block.type == "tool_result"
      and prev
      and prev.type == "tool_result"
      and prev.tool_use_id == block.tool_use_id
    then
      prev.content = prev.content .. block.content
    else
      out[#out + 1] = block
    end
  end
  return out
end

--- Transform normalized tool schemas into Anthropic tool declarations.
--- Normalized tool shape: { name=string, description?=string, input_schema?=table }.
---@param tools table[] normalized tools
---@return table[] anthropic tools (empty list omits the body `tools` field)
function adapter:_build_tools(tools)
  local out = {}
  for _, t in ipairs(tools or {}) do
    if type(t) == "table" and type(t.name) == "string" and t.name ~= "" then
      local tool = { name = t.name, input_schema = t.input_schema or t.parameters or {} }
      if type(t.description) == "string" and t.description ~= "" then
        tool.description = t.description
      end
      out[#out + 1] = tool
    end
  end
  return out
end

--- form_tools: registry definitions -> Anthropic tool declarations (W1 real
--- path). The provider-facing call name is the registry id encoded for the
--- wire (`registry.provider_name`: `server-id/tool-name` ->
--- `server-id-tool-name`; Anthropic tool names only accept
--- `^[a-zA-Z0-9_-]{1,64}$`) — unique per id, so same-named tools from
--- different servers never collide; execution resolves the wire name back to
--- the registry id through the orchestrator's provider-name map. `input_schema`
--- is copied per provider (`build_request` / `_build_tools` consumes these
--- records and never touches the normalized definition).
---@param defs table[] registry:list() definitions
---@return table[] tools { { name, description, input_schema }, ... }
function adapter:form_tools(defs)
  local registry_mod = require("maxa.runtime.tools.registry")
  local jschema = require("maxa.runtime.tools.schema")
  local out = {}
  for _, def in ipairs(defs or {}) do
    out[#out + 1] = {
      name = registry_mod.provider_name(def),
      description = def.description,
      input_schema = jschema.copy(def.input_schema),
    }
  end
  return out
end

--- Normalize a provider usage object into the schema.usage snapshot (unified
--- adapter `normalize_usage`). Anthropic reports complete usage per message, so
--- snapshots default to `final=true`; cache fields are preserved separately and
--- never double counted (normalize.normalize_usage semantics).
---@param raw table|nil provider usage object
---@param opts? table normalize options override (e.g. { final = false })
---@return table usage normalized snapshot
function adapter:normalize_usage(raw, opts)
  opts = vim.tbl_deep_extend("force", { final = true }, opts or {})
  return normalize.normalize_usage(raw, opts)
end

--- Build a typed terminal error from an Anthropic stream error frame.
---@param json table decoded error frame ({ type="error", error={...} })
---@return table event normalized error event
function adapter:_error_event(json)
  local err = type(json.error) == "table" and json.error or {}
  local ptype = type(err.type) == "string" and err.type or nil
  local class = ptype and transport.class_from_provider_type(ptype) or nil
  local code = class and normalize.class_to_code(class) or schema.ERROR.PROVIDER
  local message = (type(err.message) == "string" and err.message ~= "") and err.message
    or "Anthropic provider stream error"
  return normalize.error(schema.new_error(code, message, { provider_type = ptype, class = class }, true))
end

--- Fresh per-request stream state (request identity + accumulators).
---@param json? table message_start frame (for role/initial usage)
---@return table state
function adapter:_new_stream_state(json)
  return {
    request_id = next_request_id(),
    role = json and json.message and json.message.role or nil,
    initial_usage = json and json.message and json.message.usage or nil,
    blocks = {}, -- block index -> { type, tool={call_id,name,args=string[]} }
    terminal = false, -- error xor completed seen: late frames rejected
    cancelled = false, -- caller cancelled: late frames rejected
  }
end

--- Process one decoded Anthropic event object into normalized event(s).
---@param json table decoded frame payload
---@return table|table[]|nil event(s)
function adapter:_process_frame(json)
  local etype = type(json) == "table" and json.type or nil
  if etype == nil then
    return nil
  end

  -- SDK stream errors are always terminal (even before message_start).
  if etype == "error" then
    local state = self._stream_state or self:_new_stream_state()
    self._stream_state = state
    state.terminal = true
    return { self:_error_event(json) }
  end

  -- message_start establishes the request identity and resets all state.
  if etype == "message_start" then
    local state = self:_new_stream_state(json)
    self._stream_state = state
    return { normalize.response_started({ request_id = state.request_id, role = state.role }) }
  end

  local state = self._stream_state
  -- Late frames after a terminal (error xor completed) or after cancel are
  -- rejected by request identity (no normalized events leak through).
  if not state or state.terminal or state.cancelled then
    return nil
  end

  if etype == "content_block_start" then
    local block = type(json.content_block) == "table" and json.content_block or {}
    local btype = block.type
    if btype == "tool_use" then
      state.blocks[json.index or 0] = {
        type = "tool_use",
        tool = { call_id = block.id, name = block.name, args = {} },
      }
      return { normalize.tool_call_started(block.id, block.name) }
    end
    state.blocks[json.index or 0] = { type = btype == "thinking" and "thinking" or "text" }
    return nil
  end

  if etype == "content_block_delta" then
    local delta = type(json.delta) == "table" and json.delta or {}
    local dtype = delta.type
    if dtype == "text_delta" then
      return { normalize.message_delta(delta.text or "") }
    end
    if dtype == "thinking_delta" then
      return { normalize.reasoning_delta(delta.thinking or "") }
    end
    if dtype == "signature_delta" then
      -- Signature rides a reasoning_delta with an empty delta so consumers can
      -- attach it to the reasoning part at the message boundary.
      return { normalize.reasoning_delta("", { signature = delta.signature }) }
    end
    if dtype == "input_json_delta" then
      local index = json.index or 0
      local block = state.blocks[index]
      if not block or block.type ~= "tool_use" then
        block = { type = "tool_use", tool = { call_id = nil, name = nil, args = {} } }
        state.blocks[index] = block
      end
      local fragment = delta.partial_json or ""
      block.tool.args[#block.tool.args + 1] = fragment
      return { normalize.tool_args_delta(block.tool.call_id, fragment) }
    end
    return nil
  end

  if etype == "content_block_stop" then
    local block = state.blocks[json.index or 0]
    if block and block.type == "tool_use" and block.tool then
      local encoded = table.concat(block.tool.args)
      if encoded == "" then
        encoded = "{}" -- Anthropic tool_use input is an object; empty stays {}
      end
      return { normalize.tool_call_completed(block.tool.call_id, encoded) }
    end
    return nil
  end

  if etype == "message_delta" then
    local events = {}
    local reason = type(json.delta) == "table" and json.delta.stop_reason or nil
    if type(reason) == "string" and reason ~= "" then
      events[#events + 1] = normalize.finish_reason(reason)
    end
    -- Combined usage: input/cache from message_start + cumulative output from
    -- message_delta. Provider-reported fields stay authoritative.
    local initial = state.initial_usage or {}
    local usage_delta = type(json.usage) == "table" and json.usage or {}
    local raw = {
      input_tokens = initial.input_tokens,
      cache_creation_input_tokens = initial.cache_creation_input_tokens,
      cache_read_input_tokens = initial.cache_read_input_tokens,
      output_tokens = usage_delta.output_tokens,
    }
    events[#events + 1] = normalize.usage_updated(self:normalize_usage(raw))
    return events
  end

  if etype == "message_stop" then
    state.terminal = true
    return { normalize.completed() }
  end

  -- ping and unknown event types produce no normalized content.
  return nil
end

--- Parse one stream frame into normalized event(s) (unified adapter
--- `parse_stream`). Accepts an sse frame table ({data=..., event=...}), an
--- already-decoded event object, or raw text (JSON or SSE text).
---@param frame any raw chunk, sse frame, or decoded event object
---@return table|table[]|nil normalized event(s)
function adapter:parse_stream(frame)
  if type(frame) == "table" and type(frame.type) == "string" then
    return self:_process_frame(frame)
  end
  if type(frame) == "table" and type(frame.data) == "string" and frame.data ~= "" then
    local ok, json = pcall(vim.json.decode, frame.data)
    if ok and type(json) == "table" then
      return self:_process_frame(json)
    end
    return nil
  end
  if type(frame) == "string" then
    local ok, json = pcall(vim.json.decode, frame)
    if ok and type(json) == "table" then
      return self:_process_frame(json)
    end
    -- Raw SSE text (event:/data: lines): parse internally, flatten events.
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

--- Parse a non-stream response body into normalized events (unified adapter
--- `parse_nonstream`). Accepts a table body or raw JSON text; content blocks
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
            "invalid non-stream response body",
            { body = tostring(body):sub(1, 200) },
            true
          )
        ),
      }
    end
    json = decoded
  end
  if type(json) ~= "table" or json.type ~= "message" then
    return {
      normalize.error(
        schema.new_error(
          schema.ERROR.PROTOCOL,
          "unexpected non-stream response shape",
          { type = type(json) == "table" and json.type or nil },
          true
        )
      ),
    }
  end

  local events = {
    normalize.response_started({ request_id = next_request_id(), role = json.role }),
  }
  for _, block in ipairs(type(json.content) == "table" and json.content or {}) do
    if type(block) == "table" then
      local btype = block.type
      if btype == "text" then
        events[#events + 1] = normalize.message_delta(block.text or "")
      elseif btype == "thinking" then
        events[#events + 1] = normalize.reasoning_delta(block.thinking or block.text or "")
        if type(block.signature) == "string" and block.signature ~= "" then
          events[#events + 1] = normalize.reasoning_delta("", { signature = block.signature })
        end
      elseif btype == "tool_use" then
        local encoded = vim.json.encode(block.input or {})
        events[#events + 1] = normalize.tool_call_started(block.id, block.name)
        events[#events + 1] = normalize.tool_args_delta(block.id, encoded)
        events[#events + 1] = normalize.tool_call_completed(block.id, encoded)
      end
    end
  end
  if type(json.stop_reason) == "string" and json.stop_reason ~= "" then
    events[#events + 1] = normalize.finish_reason(json.stop_reason)
  end
  if type(json.usage) == "table" then
    events[#events + 1] = normalize.usage_updated(self:normalize_usage(json.usage))
  end
  events[#events + 1] = normalize.completed()
  return events
end

--- Mark the current stream cancelled so late frames are rejected (internal
--- surface; also invoked by the driver for cancel fixtures and by stream()).
function adapter:cancel_stream()
  local state = self._stream_state
  if state then
    state.cancelled = true
  end
end

--- Drive a real HTTP stream over the unified callback object (unified adapter
--- `stream`). params: { url, headers, normalized|body, timeout_ms?,
--- connect_timeout_ms?, proxy_env?, retries? }. Chunks are fed through the SSE
--- parser and parse_stream; a provider error frame terminalizes via on_error.
---@param params table stream request options
---@param callbacks table { on_event?=fun(event), on_done?=fun(), on_error?=fun(err) }
---@return table handle transport handle (cancel wired to cancel_stream)
function adapter:stream(params, callbacks)
  callbacks = callbacks or {}
  params = params or {}
  local body = params.body
  if body == nil then
    body = self:build_request(params, params.normalized or {})
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
    url = params.url,
    headers = params.headers,
    body = body,
    stream = true,
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
