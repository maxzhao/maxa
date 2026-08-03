-- filepath: lua/maxa/runtime/orchestrator/init.lua
--- maxa runtime orchestrator: minimal message loop driving a provider stream
--- through a session (phase 0).
---
--- Scope (see .supermax/drafts/phase0-development-plan.md §5.6): this phase ships
--- the `submit -> stream -> complete` loop only. It drives the phase-0 mock/echo
--- provider through the shared provider interface (§4.9), guards against duplicate
--- submits, and guarantees that each request reaches exactly one terminal state /
--- terminal event. It never loads codecompanion.* / mcphub.* / lua/util/hooks/*.
---
--- Alignment (read-only): upstream `Chat:submit` current_request guard +
--- `_submit_http` three-callback handling + `Chat:done` (interactions/chat/init.lua),
--- and `.supermax/specs/chat-runtime-state` control ops (submit/intent, cancel).
---
--- Events emitted here (plan §4.7):
---   "request.submitted"   carrier begins; carries session/request identity
---   "response.started"    once, on the first rendered chunk
---   "message.delta"       every incremental text chunk
---   "response.completed"  terminal success (exactly once), carries synthetic usage
---   "response.failed"     terminal provider/protocol failure (exactly once)
---   "response.cancelled"  terminal cancel via orchestrator:stop() (exactly once)
---
--- Terminal guarantees:
---   - provider drive_stream fires exactly one of on_done / on_error; orchestrator
---     additionally guards its own callback so a terminal response event and the
---     session:finish_request transition happen exactly once per request.
---   - A late/duplicate terminal callback for an already-terminal or superseded
---     request is ignored without mutation (terminal-race safety).

local schema = require("maxa.runtime.schema")
local events = require("maxa.runtime.events")
local conversation = require("maxa.runtime.conversation")
local session_mod = require("maxa.runtime.session")

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
    response_started = "response.started",
    message_delta = "message.delta",
    response_completed = "response.completed",
    response_failed = "response.failed",
    response_cancelled = "response.cancelled",
  })[key]
end

--- Build a synthetic usage record (plan §4.5). mock/echo have no real token counts,
--- so phase-0 completion emits a synthetic final usage.
---@param charset integer estimated completion character count
---@return table usage
local function synthetic_usage(charset)
  local completion_tokens = math.max(0, math.floor((charset or 0) / 4))
  return {
    prompt_tokens = 0,
    completion_tokens = completion_tokens,
    total_tokens = completion_tokens,
    source = "synthetic",
    final = true,
  }
end

--- Create an orchestrator.
---@param opts? table {
---   session?:    table, a session instance (default: a fresh session via session_mod),
---   provider?:   table, a provider adapter implementing §4.9 stream (+ map_roles),
---   events?:     table, event bus (default: global events),
---   conversation?: table, the conversation module (default: required),
---   model?:      string, display/schema model label (default "mock-model", passthrough),
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
  return setmetatable({
    session = session,
    provider = opts.provider, -- set via :use_provider in phase 0 (host wave supplies it)
    events = bus,
    conversation = conv,
    model = opts.model or "mock-model",
    messages = nil, -- message stack created lazily on first submit
    _current = nil, -- { request=..., handle=..., started=bool, buff=string, terminal=bool }
  }, { __index = M })
end

--- Attach/replace the provider adapter (phase-0 providers come from protocol).
---@param provider table provider implementing §4.9 stream
function M:use_provider(provider)
  self.provider = provider
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

--- Actually run the provider stream and wire the three callbacks. This is delegated
--- from :submit so a single submit can be made deterministic in tests.
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
    on_chunk = function(delta)
      if not is_owned(self._current, cur.request) then
        return -- late chunk for a superseded request: rejected
      end
      if self._current.terminal then
        return
      end
      if not self._current.started then
        self._current.started = true
        cur.started = true
        self.events.emit(event_name(self.events, "response_started"), {
          session_id = self.session.id,
          request_id = cur.request.id,
          generation = cur.request.generation,
          turn_id = cur.request.id,
        })
      end
      local text = type(delta) == "string" and delta or ""
      local full = append(text)
      self._current.buff = full
      cur.buff = full
      self.events.emit(event_name(self.events, "message_delta"), {
        session_id = self.session.id,
        request_id = cur.request.id,
        generation = cur.request.generation,
        delta = text,
        text = full,
      })
    end,
    on_done = function()
      if not is_owned(self._current, cur.request) or self._current.terminal then
        return
      end
      self._current.terminal = true
      cur.terminal = true
      -- Persist the assistant turn into the message stack (phase-0 in-memory).
      self:_stack():add_message({ role = "assistant", content = cur.buff or "" }, { idctx = self:_stack().idctx })
      local usage = synthetic_usage(cur.buff and #cur.buff or 0)
      self.session:finish_request(cur.request, "completed")
      self.events.emit(event_name(self.events, "response_completed"), {
        session_id = self.session.id,
        request_id = cur.request.id,
        generation = cur.request.generation,
        turn_id = cur.request.id,
        usage = usage,
      })
    end,
    on_error = function(err)
      if not is_owned(self._current, cur.request) or self._current.terminal then
        return
      end
      self._current.terminal = true
      cur.terminal = true
      local terminal_state = "failed"
      local ev = "response_failed"
      if err and err.code == schema.ERROR.CANCELLED then
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
          code = err and err.code or schema.ERROR.INTERNAL,
          message = err and err.message or tostring(err),
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
  return provider.stream(provider, params, callback)
end

--- Submit a manual user input through the loop: submit -> stream -> complete.
--- Guards against a duplicate submit while a request is active (plan §4.10 / §5.6).
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
---   async?=boolean,              true when driven asynchronously (result is the handle)
---   handle?=table,               provider handle (active/cancel) when async
---   ok?=boolean,                 true when a sync submit completed successfully
---   request?=table,              the request record
---   terminal_state?=string,       completed|failed|cancelled (sync)
---   usage?=table|nil,            synthetic usage on sync success
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

  -- Store forwarding params for provider.stream.
  self._last_params = opts.provider_params or {}

  -- Persist the visible user input as a manual turn (phase-0 in-memory).
  local meta = self:_stack():add_message({ role = "user", content = text }, { idctx = self:_stack().idctx })

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
    started = false,
    terminal = false,
    handle = nil,
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

  -- Synchronous completion: phase-0 headless/tests observe the final state here.
  -- The provider stream has already run to terminal (drive_sync). Return the result.
  local result = {
    ok = request.terminal and request.terminal.state == "completed",
    request = request,
    terminal_state = request.terminal and request.terminal.state or nil,
  }
  if result.terminal_state == "completed" then
    result.usage = synthetic_usage(cur.buff and #cur.buff or 0)
  else
    result.error_record = schema.new_error(
      schema.ERROR.CANCELLED,
      "request did not complete (see terminal_state); phase-0 sync submit",
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
