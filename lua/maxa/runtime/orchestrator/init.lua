-- filepath: lua/maxa/runtime/orchestrator/init.lua
--- maxa runtime orchestrator: minimal message loop driving a provider stream
--- through a session (phase-1 W2 parts switch).
---
--- Scope (see .supermax/drafts/phase1-implementation-plan.md §4.8): this module
--- ships the `submit -> stream -> complete` loop only. It drives the provider
--- adapter through the unified stream surface (§4.1), consumes normalized events
--- (protocol.normalize), persists messages as content parts, normalizes usage
--- (provider fields authoritative, local_estimate fallback), and guarantees that
--- each request reaches exactly one terminal state / terminal event. It never
--- loads codecompanion.* / mcphub.* / lua/util/hooks/*.
---
--- Alignment (read-only): upstream `Chat:submit` current_request guard +
--- `_submit_http` three-callback handling + `Chat:done` (interactions/chat/init.lua),
--- and `.supermax/specs/chat-runtime-state` control ops (submit/intent, cancel).
---
--- Events emitted here (W8 full set; phase-0 names kept verbatim):
---   "request.submitted"   carrier begins; carries session/request identity
---   "request.started"     once, when the provider stream produces its first
---                         content-bearing event (W8; new name, additive)
---   "response.started"    once, together with request.started
---   "message.delta"       every incremental text chunk (delta + full text)
---   "reasoning.delta"     every incremental reasoning chunk (W8)
---   "tool_call.started"   per tool call, on the first tool_call_started event (W8)
---   "tool_call.delta"     per tool-argument fragment (W8)
---   "tool_call.completed" per tool call, with the fully accumulated args (W8)
---   "usage.updated"       every normalized usage snapshot (W8)
---   "response.completed"  terminal success (exactly once), carries normalized
---                         usage + finish_reason + tool_calls summary
---   "response.failed"     terminal provider/protocol failure (exactly once)
---   "response.cancelled"  terminal cancel via orchestrator:stop() (exactly once)
---
--- Terminal guarantees:
---   - provider drive_stream fires exactly one of on_done / on_error; orchestrator
---     additionally guards its own callback so a terminal response event and the
---     session:finish_request transition happen exactly once per request.
---   - A late/duplicate terminal callback for an already-terminal or superseded
---     request is ignored without mutation (terminal-race safety).
---   - The normalized `error` / `completed` adapter events are acknowledged but are
---     NOT terminal here: the adapter's terminal callback owns the transition.

local schema = require("maxa.runtime.schema")
local events = require("maxa.runtime.events")
local conversation = require("maxa.runtime.conversation")
local session_mod = require("maxa.runtime.session")
local normalize = require("maxa.runtime.protocol.normalize")
-- Protocol registry: needed by :use_provider_record for the offline mock fallback
-- and to bind real adapters (no cycle: protocol never requires orchestrator).
local protocol = require("maxa.runtime.protocol")

local M = {}

M.name = "orchestrator"

--- Resolve an event bus (defaults to the global events module).
---@param bus? table
---@return table
local function resolve_bus(bus)
  return bus or events
end

--- Ordinal key for an event name (used to detect the first chunk reliably).
--- The phase-0 event-set constants live on the bus (`events`), falling back to the
--- literal names when a custom bus does not expose them.
---@param bus table
---@param key string constant key
---@return string
local function event_name(bus, key)
  if bus and bus.events and bus.events[key] then
    return bus.events[key]
  end
  return ({
    request_submitted = "request.submitted",
    request_started = "request.started",
    response_started = "response.started",
    message_delta = "message.delta",
    reasoning_delta = "reasoning.delta",
    tool_call_started = "tool_call.started",
    tool_call_delta = "tool_call.delta",
    tool_call_completed = "tool_call.completed",
    usage_updated = "usage.updated",
    response_completed = "response.completed",
    response_failed = "response.failed",
    response_cancelled = "response.cancelled",
  })[key]
end

--- Resolve the final normalized usage for a completed request: a provider-final
--- snapshot wins; otherwise a local estimate fills the unknown fields
--- (streaming-usage §Usage: local estimates mark source: local_estimate).
---@param cur table _current record (usage/buff/input_chars)
---@return table usage normalized usage snapshot
local function final_usage(cur)
  local usage = cur.usage
  if usage and (usage.final == true or usage.source == "provider_final") then
    return usage
  end
  return normalize.local_estimate({
    input_chars = cur.input_chars,
    output_chars = cur.buff and #cur.buff or 0,
  })
end

--- Classify a provider error into a runtime error code: the granular transport
--- class (cause.class) maps to the W2 error families; otherwise the adapter's
--- own code is kept verbatim.
---@param err table|nil typed error from the provider stream
---@return string code schema.ERROR.*
local function classify_error_code(err)
  if err and err.cause and type(err.cause.class) == "string" then
    return normalize.class_to_code(err.cause.class)
  end
  return (err and err.code) or schema.ERROR.INTERNAL
end

--- Create an orchestrator.
---@param opts? table {
---   session?:    table, a session instance (default: a fresh session via session_mod),
---   provider?:   table, a provider adapter implementing the unified stream surface,
---   events?:     table, event bus (default: global events),
---   conversation?: table, the conversation module (default: required),
---   model?:      string, display/schema model label (default "mock-model", passthrough),
---   project_id?: string, session project id (forwarded to session creation)
--- }
---@return table orchestrator
function M.new(opts)
  opts = opts or {}
  local bus = resolve_bus(opts.events)
  local conv = opts.conversation or conversation
  local session = opts.session or session_mod.new({
    project_id = opts.project_id,
    events = bus,
  })
  local self = setmetatable({
    session = session,
    provider = opts.provider, -- set via :use_provider
    provider_record = nil, -- resolved config record (set via :use_provider_record)
    _real_adapter = false, -- true when the bound provider is a real protocol adapter
    events = bus,
    conversation = conv,
    model = opts.model or "mock-model",
    messages = nil, -- message stack created lazily on first submit
    _current = nil, -- { request=..., handle=..., started=bool, buff=string,
    --                reasoning=string, tool_calls=table[], finish_reason=string|nil,
    --                usage=table|nil, input_chars=int, terminal=bool }
  }, { __index = M })
  if opts.provider_record then
    self:use_provider_record(opts.provider_record)
  end
  return self
end

--- Attach/replace the provider adapter (unified stream surface).
---@param provider table provider implementing stream/parse_stream/normalize_usage
function M:use_provider(provider)
  self.provider = provider
  self.provider_record = nil
  self._provider_params = nil
  self._real_adapter = false
  return self
end

--- Attach a resolved config provider record (config.resolve_provider output).
--- Real provider path (plan §4.8): when the protocol adapter is registered AND an
--- api key is available, the adapter is bound and streamed through the transport
--- (the adapter owns transport/sse). Without a key or adapter (offline dev/UI)
--- the local mock provider is bound so the Chat view keeps working; the record's
--- model label is still applied for display.
---@param record table normalized provider record from config.resolve_provider
---@param opts? table {
---   params?: table pre-built adapter setup params (W10 host wiring: flattened
---     model/base_url/api_key_env/connect_timeout_ms/timeout_ms/proxy_env, plus
---     anthropic url/headers). When absent the raw record is passed to
---     adapter:setup as before (the record carries timeouts nested under
---     `request`, so pre-built params are required for full request options).
--- }
---@return self
function M:use_provider_record(record, opts)
  opts = opts or {}
  self.provider_record = record
  self._provider_params = opts.params or nil
  self._real_adapter = false
  if record and record.adapter and type(record.api_key) == "string" and record.api_key ~= "" then
    self.provider = record.adapter
    self.model = record.model or self.model
    self._real_adapter = true
  else
    self.provider = protocol.get(protocol.providers.mock)
    if record then
      self.model = record.model or self.model
    end
  end
  return self
end

---@return boolean true when a request is currently in flight.
function M:is_busy()
  return self.session:is_busy()
end

--- Ensure a message stack exists and return it.
---@return table stack
function M:_stack()
  if not self.messages then
    self.messages = self.conversation.new_stack()
  end
  return self.messages
end

--- Cancel the current provider stream (soft-stop -> terminal CANCELLED).
--- Idempotent: safe to call repeatedly; only the first cancel reaches a terminal
--- state. Returns true when this call performed the cancel.
---@return boolean cancelled
function M:stop()
  local cur = self._current
  if not cur or not cur.handle then
    return false
  end
  if cur.terminal then
    return false
  end
  -- provider handle.cancel is a closure; it deliberately takes no `self` and at most
  -- an optional on-cancelled callback. Calling it with `cur.handle` (a table) as that
  -- callback would crash ("attempt to call a table value") once the cancel wins the
  -- terminal transition. Call zero-arg and read the boolean return.
  local ok, res = pcall(cur.handle.cancel)
  if ok and res then
    -- handle.cancel returned true: this call won the terminal transition.
    return res
  end
  -- handle.cancel failed (e.g. provider already terminal) — safe no-op.
  return false
end

--- Request ownership check: a terminal callback must act only on the request that
--- created it (stale/superseded callbacks are ignored).
---@param cur table current _current record
---@param request table the request that owns this callback
---@return boolean
local function is_owned(cur, request)
  return cur and cur.request and cur.request.id == request.id
end

--- Emit `request.started` + `response.started` exactly once per request. The
--- first content-bearing normalized event (response_started / message_delta /
--- reasoning_delta / tool_call_started) triggers it; mock/echo emit no
--- response_started, so the first-delta path covers them too.
---@param self table orchestrator
---@param cur table _current record
local function mark_started(self, cur)
  if cur.started then
    return
  end
  cur.started = true
  self._current.started = true
  self.events.emit(event_name(self.events, "request_started"), {
    session_id = self.session.id,
    request_id = cur.request.id,
    generation = cur.request.generation,
    turn_id = cur.request.id,
  })
  self.events.emit(event_name(self.events, "response_started"), {
    session_id = self.session.id,
    request_id = cur.request.id,
    generation = cur.request.generation,
    turn_id = cur.request.id,
  })
end

--- Tool-call summary for the terminal response.completed payload.
---@param cur table _current record (tool_calls)
---@return table[] list of { call_id, name }
local function tool_calls_summary(cur)
  local out = {}
  for _, tc in ipairs(cur.tool_calls or {}) do
    out[#out + 1] = { call_id = tc.call_id, name = tc.name }
  end
  return out
end

--- Persist the assistant turn into the message stack as content parts.
--- The committed assistant message stores normalized parts only (reasoning,
--- text, tool_call parts — W8), never raw provider envelopes.
---@param cur table _current record (request/buff/reasoning/tool_calls)
local function persist_assistant(self, cur)
  local parts = {}
  local reasoning = cur.reasoning or ""
  if reasoning ~= "" then
    parts[#parts + 1] = self.conversation.reasoning_part(reasoning, {
      provider = (self.provider and self.provider.name) or nil,
      retained = true,
    })
  end
  local text = cur.buff or ""
  if text ~= "" then
    parts[#parts + 1] = self.conversation.text_part(text)
  end
  for _, tc in ipairs(cur.tool_calls or {}) do
    -- Empty JSON object stays an object (fixture contract: empty JSON objects
    -- remain objects); the schema rejects empty-string arguments.
    local args = tc.arguments
    if type(args) ~= "string" or args == "" then
      args = "{}"
    end
    local opts = {}
    if type(tc.provider_id) == "string" then
      opts.provider_id = tc.provider_id
    end
    parts[#parts + 1] = self.conversation.tool_call_part(tc.call_id, tc.name, args, opts)
  end
  self
    :_stack()
    :add_message({ role = "assistant", content = parts }, { idctx = self:_stack().idctx, turn_id = cur.request.id })
end

--- Actually run the provider stream and wire the unified callbacks. This is
--- delegated from :submit so a single submit can be made deterministic in tests.
---@param cur table _current record (request, buff, started, terminal)
---@param async boolean|nil drive provider asynchronously (UI) or synchronously (tests)
---@return table provider handle (active/cancel)
local function run_stream(self, cur, async)
  local provider = self.provider
  assert(provider, "orchestrator:submit: no provider attached; call :use_provider()")

  local buff = {}
  local function append(text)
    buff[#buff + 1] = text
    return table.concat(buff)
  end

  local callback = {
    -- Normalized event consumer (protocol.normalize shapes; W8 full set).
    -- Every content-bearing event is accumulated into `cur` and forwarded to the
    -- bus; tool calls are RECORDED as tool_call parts (never executed — tool
    -- batching/continuation is a phase-2 concern).
    on_event = function(event)
      if not is_owned(self._current, cur.request) then
        return -- late event for a superseded request: rejected
      end
      if self._current.terminal then
        return
      end
      local etype = event and event.type
      if etype == normalize.events.response_started then
        mark_started(self, cur)
      elseif etype == normalize.events.message_delta then
        mark_started(self, cur)
        local text = (event and event.delta) or ""
        local full = append(text)
        self._current.buff = full
        cur.buff = full
        self.events.emit(event_name(self.events, "message_delta"), {
          session_id = self.session.id,
          request_id = cur.request.id,
          generation = cur.request.generation,
          turn_id = cur.request.id,
          delta = text,
          text = full,
        })
      elseif etype == normalize.events.reasoning_delta then
        mark_started(self, cur)
        local delta = (event and event.delta) or ""
        local full = (cur.reasoning or "") .. delta
        if event and type(event.text) == "string" then
          full = event.text -- full accumulated text wins when provided
        end
        self._current.reasoning = full
        cur.reasoning = full
        self.events.emit(event_name(self.events, "reasoning_delta"), {
          session_id = self.session.id,
          request_id = cur.request.id,
          generation = cur.request.generation,
          turn_id = cur.request.id,
          delta = delta,
          text = full,
        })
      elseif etype == normalize.events.tool_call_started then
        mark_started(self, cur)
        local call_id = event and event.call_id
        local name = (event and event.name) or "?"
        if type(call_id) == "string" and call_id ~= "" then
          -- Track for persistence; dedupe by stable call id.
          local exists = false
          for _, c in ipairs(cur.tool_calls) do
            if c.call_id == call_id then
              exists = true
              break
            end
          end
          if not exists then
            cur.tool_calls[#cur.tool_calls + 1] = {
              call_id = call_id,
              name = name,
              arguments = "",
              provider_id = event.provider_id,
            }
          end
        end
        self.events.emit(event_name(self.events, "tool_call_started"), {
          session_id = self.session.id,
          request_id = cur.request.id,
          generation = cur.request.generation,
          turn_id = cur.request.id,
          call_id = call_id,
          name = name,
        })
      elseif etype == normalize.events.tool_args_delta then
        local call_id = event and event.call_id
        local fragment = (event and event.fragment) or ""
        for _, c in ipairs(cur.tool_calls) do
          if c.call_id == call_id then
            c.arguments = c.arguments .. fragment -- UTF-8 byte-wise accumulation
            break
          end
        end
        self.events.emit(event_name(self.events, "tool_call_delta"), {
          session_id = self.session.id,
          request_id = cur.request.id,
          generation = cur.request.generation,
          turn_id = cur.request.id,
          call_id = call_id,
          fragment = fragment,
        })
      elseif etype == normalize.events.tool_call_completed then
        local call_id = event and event.call_id
        local name
        for _, c in ipairs(cur.tool_calls) do
          if c.call_id == call_id then
            name = c.name
            -- The completed event carries the fully accumulated encoded args
            -- (authoritative over delta fragments).
            if type(event.encoded_args) == "string" and event.encoded_args ~= "" then
              c.arguments = event.encoded_args
            end
            break
          end
        end
        self.events.emit(event_name(self.events, "tool_call_completed"), {
          session_id = self.session.id,
          request_id = cur.request.id,
          generation = cur.request.generation,
          turn_id = cur.request.id,
          call_id = call_id,
          name = name,
          arguments = event and event.encoded_args,
        })
      elseif etype == normalize.events.usage_updated then
        -- Latest normalized snapshot wins; a provider-final snapshot is kept as-is
        -- by final_usage (streaming-usage: final correction is traceable).
        if event and event.usage then
          self._current.usage = event.usage
          cur.usage = event.usage
          self.events.emit(event_name(self.events, "usage_updated"), {
            session_id = self.session.id,
            request_id = cur.request.id,
            generation = cur.request.generation,
            turn_id = cur.request.id,
            usage = event.usage,
          })
        end
      elseif etype == normalize.events.finish_reason then
        if type(event.reason) == "string" then
          self._current.finish_reason = event.reason
          cur.finish_reason = event.reason
        end
      end
      -- error / completed normalized events are acknowledged but are NOT terminal
      -- here: the adapter's terminal callback (on_done/on_error) owns the
      -- exactly-once terminal transition (adapter contract).
    end,
    on_done = function()
      if not is_owned(self._current, cur.request) or self._current.terminal then
        return
      end
      self._current.terminal = true
      cur.terminal = true
      persist_assistant(self, cur)
      local usage = final_usage(cur)
      self.session:finish_request(cur.request, "completed")
      self.events.emit(event_name(self.events, "response_completed"), {
        session_id = self.session.id,
        request_id = cur.request.id,
        generation = cur.request.generation,
        turn_id = cur.request.id,
        usage = usage,
        finish_reason = cur.finish_reason,
        tool_calls = tool_calls_summary(cur),
      })
    end,
    on_error = function(err)
      if not is_owned(self._current, cur.request) or self._current.terminal then
        return
      end
      self._current.terminal = true
      cur.terminal = true
      cur.last_error = err -- retained for the sync submit result path
      local code = classify_error_code(err)
      local terminal_state = "failed"
      local ev = "response_failed"
      if code == schema.ERROR.CANCELLED then
        terminal_state = "cancelled"
        ev = "response_cancelled"
      end
      self.session:finish_request(cur.request, terminal_state)
      self.events.emit(event_name(self.events, ev), {
        session_id = self.session.id,
        request_id = cur.request.id,
        generation = cur.request.generation,
        turn_id = cur.request.id,
        error = {
          code = code,
          message = (err and err.message) or tostring(err),
          cause = (err and err.cause) or nil,
          terminal = true,
        },
      })
    end,
  }

  local params = {
    model = self.model,
    async = async,
  }
  -- Forward extra stream params (chunks / recording / delay / error / cancel) so the
  -- host / tests can drive the mock/echo provider deterministically.
  if self._last_params then
    for k, v in pairs(self._last_params) do
      if k ~= "model" and k ~= "async" then
        params[k] = v
      end
    end
  end

  if self._real_adapter and self.provider_record then
    -- Real provider path (plan §4.8): adapter:setup(record) then adapter:stream.
    -- The transport lives inside the adapter; params.normalized carries the
    -- normalized conversation snapshot (message-context-target §Normalized records).
    -- W10: the host may pre-build the setup params (flattened timeouts/proxy_env,
    -- anthropic url/headers) via use_provider_record(record, { params = ... });
    -- without them the raw record is passed to setup as before.
    -- A start failure is surfaced as a terminal error through the same callback
    -- (exactly-once), with a no-op handle so :stop() stays safe.
    local record = self.provider_record
    local sp, serr = provider.setup(provider, self._provider_params or record)
    if not sp then
      callback.on_error(schema.new_error(schema.ERROR.CONFIGURATION, tostring(serr), nil, true))
      return {
        active = false,
        cancel = function()
          return false
        end,
      }
    end
    params = sp
    params.model = self.model or sp.model
    params.normalized = { messages = self:_stack():to_table(), tools = {} }
    -- Preserve host-provided setup extras that adapter:setup normalized away
    -- (e.g. anthropic_messages url/headers: setup() does not carry them, but
    -- stream() requires them — live.lua merges them into st_params the same way).
    if self._provider_params then
      for k, v in pairs(self._provider_params) do
        if params[k] == nil then
          params[k] = v
        end
      end
    end
    local handle, herr = provider.stream(provider, params, callback)
    if not handle then
      callback.on_error(schema.new_error(schema.ERROR.PROVIDER, tostring(herr), nil, true))
      return {
        active = false,
        cancel = function()
          return false
        end,
      }
    end
    return handle
  end

  return provider.stream(provider, params, callback)
end

--- Submit a manual user input through the loop: submit -> stream -> complete.
--- Guards against a duplicate submit while a request is active (plan §4.10 / §5.6)
--- and against empty submissions (conversation.validate_submission).
---@param text string user input
---@param opts? table {
---   provider_params?: table, forwarded to provider.stream (chunks/recording/delay/...)
---   async?:           boolean, drive provider asynchronously (UI); default false (sync,
---                     deterministic, good for headless tests)
---   intent?:          string, submit intent ("manual" default; phase-0 only manual)
--- }
---@return table result {
---   rejected?=boolean,           true when the submit was refused
---   error?=table,                typed error when rejected
---   diagnostic?=string,          exact composition diagnostic when rejected
---   async?=boolean,              true when driven asynchronously (result is the handle)
---   handle?=table,               provider handle (active/cancel) when async
---   ok?=boolean,                 true when a sync submit completed successfully
---   request?=table,              the request record
---   terminal_state?=string,       completed|failed|cancelled (sync)
---   usage?=table|nil,            normalized usage on sync success
---   error_record?=table|nil,     typed error on sync failure/cancel
--- }
function M:submit(text, opts)
  opts = opts or {}
  -- Duplicate-submit guard (plan §4.10): busy session rejects a second manual submit
  -- WITHOUT creating a second request identity.
  if self.session:is_busy() then
    return {
      rejected = true,
      error = schema.new_error(
        schema.ERROR.INVALID_ARGUMENT,
        "a request is already in progress; duplicate manual submit rejected (phase 0 policy)",
        { session_id = self.session.id },
        false
      ),
    }
  end
  if self.session:is_closed() then
    return {
      rejected = true,
      error = schema.new_error(
        schema.ERROR.INVALID_ARGUMENT,
        ("session %s is closed; cannot submit"):format(self.session.id),
        nil,
        true
      ),
    }
  end

  -- Submission validation (message-context-target §Submission validation):
  -- empty-submit is refused before any request identity is created; context-only
  -- and continuation submissions are accepted (W2 manual path passes text only).
  local vres = self.conversation.validate_submission({ text = text }, {
    project_id = self.session.project_id,
  })
  if not vres.ok then
    return {
      rejected = true,
      error = vres.error,
      diagnostic = vres.diagnostic,
    }
  end

  -- Store forwarding params for provider.stream.
  self._last_params = opts.provider_params or {}

  -- Persist the visible user input as a manual turn (content parts; W2 text only).
  self:_stack():add_message(
    { role = "user", content = { self.conversation.text_part(vres.instruction) } },
    { idctx = self:_stack().idctx }
  )

  -- Start a new request through the session (advances generation, session -> busy).
  local request, start_err = self.session:start_request({
    intent = "manual",
  })
  if not request then
    return {
      rejected = true,
      error = start_err,
    }
  end

  -- Carry the request (record the request identity for stale-callback checks).
  local cur = {
    request = request,
    buff = "",
    reasoning = "", -- accumulated reasoning text (reasoning_delta)
    tool_calls = {}, -- ordered { call_id, name, arguments, provider_id } records
    finish_reason = nil, -- latest finish_reason label
    started = false,
    terminal = false,
    handle = nil,
    usage = nil, -- latest normalized usage from usage_updated events
    input_chars = #vres.instruction,
  }
  self._current = cur

  self.events.emit(event_name(self.events, "request_submitted"), {
    session_id = self.session.id,
    request_id = request.id,
    generation = request.generation,
    turn_id = request.id,
    intent = "manual",
  })

  local async = not not opts.async
  local handle = run_stream(self, cur, async)
  cur.handle = handle

  if async then
    return { ok = true, async = true, handle = handle, request = request }
  end

  -- Synchronous completion: headless/tests observe the final state here.
  -- The provider stream has already run to terminal (drive_sync). Return the result.
  local result = {
    ok = request.terminal and request.terminal.state == "completed",
    request = request,
    terminal_state = request.terminal and request.terminal.state or nil,
  }
  if result.terminal_state == "completed" then
    result.usage = final_usage(cur)
  else
    result.error_record = schema.new_error(
      classify_error_code(cur.last_error or nil),
      "request did not complete (see terminal_state); phase-1 sync submit",
      { terminal_state = result.terminal_state },
      result.terminal_state == "cancelled"
    )
  end
  return result
end

--- @return table snapshot { session = table, busy = boolean, model = string }
function M:snapshot()
  return {
    session = self.session:snapshot(),
    busy = self.session:is_busy(),
    model = self.model,
  }
end

--- Close the orchestrator + underlying session. Idempotent.
---@return boolean changed
function M:close()
  self._current = nil
  self._last_params = nil
  return self.session:close()
end

return M
