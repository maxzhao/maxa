-- filepath: lua/maxa/runtime/protocol/init.lua
--- maxa runtime protocol layer: unified adapter interface + mock/echo providers
--- + real-protocol adapter registry (phase-1 W2).
---
--- Scope (see .supermax/drafts/phase1-implementation-plan.md §4.1): this module
--- ships the unified adapter interface that every provider conforms to
--- (mock/echo today; real four-protocol adapters register in W4-W7 via
--- `register_adapter`). `tools/mcp/skills/compat` remain placeholders in other
--- subagents' wave scope; do not implement them here.
---
--- Unified adapter interface (plan §4.1):
---
---   adapter = {
---     name          = "mock" | "echo" | <adapter name>,
---     protocol      = "mock" | "echo" | config.PROTOCOLS value,
---     capabilities  = { vision=bool, tools=bool, reasoning=bool }, -- capability matrix
---     setup(self, opts) -> params | nil, err,      -- config normalization
---     build_request(self, params, normalized) -> body, -- normalized -> provider body
---     parse_stream(self, frame) -> normalized_event|nil, -- raw frame -> event
---     parse_nonstream(self, body) -> normalized_event,   -- non-stream response -> event
---     normalize_usage(self, raw) -> usage|nil,           -- provider usage -> snapshot
---     stream(self, params, callbacks) -> handle,         -- { cancel, active }
---   }
---
--- Normalized event stream (protocol.normalize): adapters emit
---   response_started / message_delta / reasoning_delta / tool_call_started /
---   tool_args_delta / tool_call_completed / usage_updated / finish_reason /
---   error / completed. The orchestrator consumes only these events.
---
--- stream callback contract:
---   callbacks = {
---     on_event(event):   normalized event (see normalize.lua M.events)
---     on_done():         terminal success (exactly once)
---     on_error(err):     terminal failure, typed error per §4.6; exactly once
---   }
---   Exactly one terminal callback (on_done xor on_error) fires per stream.
---   `on_chunk` is kept as a raw-text fallback for legacy drivers (when
---   `on_event` is absent, raw chunks are delivered as-is).
---
--- stream returns a control handle:
---   { cancel = function(cancelled_cb?) -> boolean, active = boolean }
---   handle.cancel() requests an ordered stop: it aborts remaining chunks and,
---   if a terminal callback has not yet fired, fires on_error with a terminal
---   CANCELLED error (exactly once).
---
--- Injection (mock/echo, see §4.9): opts.delay (ms between chunks), opts.error
--- (inject a provider failure exactly once after opts.error_at chunks), opts.cancel
--- (auto-cancel after opts.error_at chunks). Recording mode (opts.recording) replays
--- a captured chunk sequence deterministically for headless/floating verification.
---
--- Topology: schema -> protocol. This module depends only on
--- lua/maxa/runtime/schema + lua/maxa/runtime/protocol/normalize (typed errors,
--- usage shape, normalized events). It never loads codecompanion.* / mcphub.* /
--- lua/util/hooks/*.

local schema = require("maxa.runtime.schema")
local normalize = require("maxa.runtime.protocol.normalize")

-- LazyVim ecosystem dependency (allowed; NOT a codecompanion/mcphub/hooks import).
-- plenary.async drives the async streaming coroutine. Its core module only loads
-- pure-Lua helpers eagerly (`plenary.async.async`); heavy submodules (uv_async etc.)
-- are lazy-loaded via a metatable __index, so requiring it here is safe even when
-- vim.loop is unavailable in an edge environment. R-02 (revamp): replaces the
-- previous hand-written vim.defer_fn timer chain for the async stream driver.
-- plenary.async.util exposes the async sleep / scheduler primitives we use below
-- (`util.sleep` = async-wrapped vim.defer_fn; `util.scheduler` = async-wrapped
-- vim.schedule), so we do NOT re-wrap them by hand.
local async = require("plenary.async")
local async_util = require("plenary.async.util")

local M = {}

M.name = "protocol"

--- Provider name constants (mock/echo are the phase-0 local providers; real
--- adapters register by protocol name via M.register_adapter).
M.providers = {
  mock = "mock",
  echo = "echo",
}

------------------------------------------------------------
-- Streaming driver core
------------------------------------------------------------
-- A stream is driven by an ordered "script" of steps. `generate_script` turns a
-- provider's streaming spec (chunks / delay / error / cancel / recording) into a
-- deterministic step list, so the same spec produces identical behavior whether
-- driven synchronously (headless / tests) or asynchronously (floating UI render).
--
-- Step shapes:
--   { type="chunk", delta=<string> }
--   { type="done" }
--   { type="error", err=<typed_error_table, §4.6> }

--- Build a monotonic request/chunk identity string.
---@return string
local function monotonic_id()
  local counter = 0
  return function(prefix)
    counter = counter + 1
    return ("%s-%s-%s"):format(prefix or "proto", os.time(), counter)
  end
end
local next_id = monotonic_id()

--- Generate the ordered streaming script from a spec (pure, deterministic).
---@param spec table { chunks=list<string>, delay_after_every=int, error_at=int|nil,
---                     cancel_at=int|nil, inject_error=? function(err code,msg,len) }
---@return table script ordered array of step tables (chunk/done/error)
local function generate_script(spec)
  local chunks = spec.chunks or {}
  local chunks_total = #chunks
  local delay_after_every = spec.delay_after_every or 0
  local error_at = spec.error_at -- 1-based position to fire a provider error, else nil
  local cancel_at = spec.cancel_at -- 1-based position to auto-cancel, else nil

  local script = {}
  for i, chunk in ipairs(chunks) do
    -- A supplied error fires at EXACTLY one position (error_at); if cancel is set
    -- before error_at, cancel wins (auto-cancel is also terminal). The chunk AT that
    -- position is NOT delivered: the position is the failure point, so the terminal
    -- error replaces it and the script stops (no further chunks).
    if error_at and i == error_at then
      script[#script + 1] = {
        type = "error",
        err = (spec.inject_error and spec.inject_error(i, chunks_total)) or schema.new_error(
          schema.ERROR.PROVIDER,
          ("mock provider failure injected at chunk %d/%d"):format(i, chunks_total),
          { at = i },
          true
        ),
        id = next_id("err"),
      }
      break
    elseif cancel_at and i == cancel_at then
      script[#script + 1] = {
        type = "error",
        err = schema.new_error(
          schema.ERROR.CANCELLED,
          ("stream auto-cancelled after chunk %d/%d"):format(i, chunks_total),
          { at = i },
          true
        ),
        id = next_id("cancel"),
      }
      break
    end
    script[#script + 1] = {
      type = "chunk",
      delta = chunk,
      id = next_id("chunk"),
      index = i,
    }
    if i > 1 and delay_after_every > 0 and (i - 1) % delay_after_every == 0 then
      script[#script + 1] = { type = "yield", ms = delay_after_every }
    end
  end
  -- No terminal step was added (no error/cancel and chunks streamed to end): done.
  local saw_terminal = false
  for _, step in ipairs(script) do
    if step.type == "done" or step.type == "error" then
      saw_terminal = true
    end
  end
  if not saw_terminal then
    script[#script + 1] = { type = "done", id = next_id("done") }
  end
  return script
end

-- Async stream-driver leaves (plenary.async.util primitives): when called from
-- inside an async.void coroutine they auto-yield and resume on nvim's event loop.
--   sleep_leaf(ms):     waits ms -> `async_util.sleep` (async-wrapped vim.defer_fn)
--   yield_now_leaf():   one scheduler turn -> `async_util.scheduler` (async-wrapped
--                       vim.schedule).
-- They are only used when a nvim event loop exists (`vim.defer_fn`); otherwise the
-- async path falls back to the synchronous driver (headless / no-loop environments).
local sleep_leaf, yield_now_leaf
if vim and vim.defer_fn then
  sleep_leaf = async_util.sleep
  yield_now_leaf = async_util.scheduler
end

--- Drive a scripted stream against a callback object.
---@param script table ordered step array from generate_script
---@param callback table { on_chunk?=fun(delta), on_done?=fun(), on_error?=fun(err) }
---@param opts? table { async=bool } if true, drives the stream through a
---                    plenary.async coroutine so the streaming renderer gets to
---                    update between chunks and an ordered `cancel()` can interrupt
---                    an in-flight stream; if false (default) fires synchronously
---                    for deterministic headless/tests/recording playback.
---@return table handle { cancel=fun(on_cancelled?):boolean, active=bool, last_error?=table }
local function drive_stream(script, callback, opts)
  local async_requested = not not (opts and opts.async)
  -- Async requires a nvim event loop (vim.defer_fn). Without one (bare luajit,
  -- headless with no loop), always fall back to the synchronous driver.
  local use_async = async_requested and sleep_leaf ~= nil
  local callbacks = callback or {}
  local terminated = false
  local active = true
  local idx = 0

  -- Control handle returned to the caller. Declared as a local table up front so the
  -- terminal helpers below capture it as a proper upvalue (Lua scoping), then the
  -- mutable fields are populated after helper definition.
  local handle = {
    active = active,
    last_error = nil,
  }

  --- Fire a terminal callback exactly once. Returns true if it was this call that
  --- performed the terminal transition; false if already terminated.
  local function fire_terminal(kind, arg)
    if terminated then
      return false
    end
    terminated = true
    active = false
    handle.active = false
    local fn = callbacks[kind]
    if fn then
      local ok, err = pcall(fn, arg)
      if not ok then
        -- A failing terminal callback must not abort the terminal transition; it is
        -- surfaced via the handle as `last_error` for diagnostics.
        handle.last_error = { terminal_kind = kind, err = tostring(err) }
      end
    end
    return true
  end

  -- Ordered cancel: if a terminal already fired, this is a no-op. Otherwise it
  -- aborts remaining chunks and terminalises with a terminal CANCELLED error once.
  handle.cancel = function(on_cancelled)
    if not handle.active then
      return false
    end
    -- Stop stepping any pending scheduled chunk after a cancel request.
    handle.active = false
    active = false
    local terminal_won =
      fire_terminal("on_error", schema.new_error(schema.ERROR.CANCELLED, "stream cancelled by caller", nil, true))
    if on_cancelled and terminal_won then
      on_cancelled()
    end
    return terminal_won
  end

  --- Isolated chunk fire: a failing on_chunk is non-fatal (best-effort rendering)
  --- and never aborts the terminal transition; it is surfaced via handle.last_error.
  local function fire_chunk(step_idx, delta)
    local fn = callbacks.on_chunk
    if fn then
      local ok, err = pcall(fn, delta)
      if not ok then
        handle.last_error = { at = step_idx, err = tostring(err) }
      end
    end
  end

  -- Synchronous driver: fire every step inline (fully deterministic, good for
  -- tests / headless verification / recording playback).
  local function drive_sync()
    for i = 1, #script do
      if not active then
        break
      end
      idx = i
      local step = script[i]
      if step.type == "chunk" then
        fire_chunk(step.index, step.delta)
      elseif step.type == "yield" then
        -- sync driver ignores explicit async yields
      elseif step.type == "error" then
        fire_terminal("on_error", step.err)
      elseif step.type == "done" then
        fire_terminal("on_done")
      end
    end
    if active then
      -- Loop ended without a terminal step (shouldn't happen given generate_script
      -- always appends one) — safety net.
      fire_terminal("on_done")
    end
    return handle
  end

  -- Async driver (plenary.async, R-02): a single async.void coroutine steps the
  -- script, auto-yielding to nvim's event loop between choreographic points. The
  -- initial yield_now defers the first step so `stream()` can return its handle
  -- before any chunk fires. A regular chunk yields once (renderer update window); a
  -- `yield` step sleeps `ms`; `cancel()` sets active=false so the next resume exits
  -- the loop. Terminal once-ness and per-callback isolation match the sync driver.
  local function drive_async()
    local function step_async()
      yield_now_leaf() -- deferred first step (mirrors the original schedule(0) start)
      for i = 1, #script do
        if not active then
          return
        end
        local step = script[i]
        if step.type == "chunk" then
          fire_chunk(step.index, step.delta)
          yield_now_leaf() -- one scheduler turn between chunks so the renderer updates
        elseif step.type == "yield" then
          sleep_leaf(step.ms or 0)
        elseif step.type == "error" then
          fire_terminal("on_error", step.err)
        elseif step.type == "done" then
          fire_terminal("on_done")
        end
      end
      if active then
        fire_terminal("on_done") -- safety net (generate_script always appends one)
      end
    end

    async.void(step_async)()
    return handle
  end

  if use_async then
    return drive_async()
  end
  return drive_sync()
end

------------------------------------------------------------
-- Provider base / helpers
------------------------------------------------------------

--- Build the default streaming spec from params.
---@param params table run-time stream params { chunks?, recording?, delay?, error?, error_at?, cancel?, cancel_at? }
---@return table spec normalized spec table for generate_script
local function build_stream_spec(params)
  local spec = {
    chunks = nil,
    delay_after_every = 0,
    error_at = nil,
    cancel_at = nil,
    inject_error = params and params.inject_error,
  }
  -- Recording mode: replay an explicitly provided, already-captured chunk sequence.
  if params and params.recording and type(params.recording) == "table" then
    local flat = {}
    local function collect(v)
      if type(v) == "string" then
        flat[#flat + 1] = v
      elseif type(v) == "table" then
        for _, item in ipairs(v) do
          collect(item)
        end
      end
    end
    collect(params.recording)
    spec.chunks = flat
  elseif params and params.chunks and type(params.chunks) == "table" then
    spec.chunks = vim.deepcopy(params.chunks)
  else
    -- Default echo body (stable deterministic default for headless smoke tests).
    spec.chunks = { "Hello from maxa ", "mock/echo provider." }
  end

  if params and params.delay then
    spec.delay_after_every = params.delay
  end
  if params and params.error and (params.error_at or 1) then
    spec.error_at = params.error_at or 1
  end
  if params and params.cancel and params.cancel_at then
    spec.cancel_at = params.cancel_at
  end
  return spec
end

--- Validate a provider setup spec against the provider's declared `schema`.
---@param provider table adapter object
---@param schema_def table provider.schema field definitions (keys -> field)
---@param params table setup params
---@return boolean ok
---@return nil|table err validation error map { key -> message }
local function validate_setup(provider, schema_def, params)
  if not schema_def or vim.tbl_isempty(schema_def or {}) then
    return true, nil -- no schema declared: accept any params on setup
  end
  local errs = schema.validate(schema_def, params or {})
  if errs then
    return false, errs
  end
  return true, nil
end

--- Adapter factory for the local mock/echo providers. Both share this base so
--- their unified adapter interface stays identical (real four-protocol adapters
--- register in W4-W7 through M.register_adapter with the same surface).
---@param name "mock"|"echo"
---@return table adapter object
local function make_provider(name)
  local provider = {}

  provider.name = name
  -- Protocol identifier: mock/echo are their own local protocol names (they are
  -- NOT config.PROTOCOLS values; config resolves those through get_adapter).
  provider.protocol = name
  -- Capability declaration (config capability-matrix checks real protocols;
  -- mock/echo declare no vision/tools/reasoning).
  provider.capabilities = { vision = false, tools = false, reasoning = false }
  -- Declared setup schema (subset of §4.9: model/stream options).
  provider.schema = {
    model = { type = "string", optional = true, default = "mock-model" },
    delay = { type = "integer", optional = true, default = 0 },
    -- normalized parameters set by setup(); recorded for callers/telemetry.
    _params = { type = "map", optional = true, default = nil },
  }

  --- Parse and normalize params; returns normalized params, or nil+error on
  --- validation failure (unified adapter `setup`).
  ---@param opts table caller-supplied params
  ---@return table|nil params normalized params
  ---@return nil|table|string err validation error
  function provider.setup(self, opts)
    opts = opts or {}
    local ok, err = validate_setup(self, self.schema, opts)
    if not ok then
      return nil, ("%s.setup: invalid params: %s"):format(self.name, vim.inspect(err))
    end
    local params = {
      model = opts.model or "mock-model",
      delay = opts.delay or 0,
    }
    self._params = params
    return params, nil
  end

  --- Build the provider request body from normalized parts (unified adapter
  --- `build_request`). mock/echo produce a deterministic local body carrying a
  --- parts projection (role + text parts) so live/fixture validation can compare
  --- it against expected bodies.
  ---@param params table setup params (model/delay)
  ---@param normalized table { messages=table[], tools=table[] } normalized parts messages
  ---@return table body provider request body
  function provider.build_request(self, params, normalized)
    normalized = normalized or {}
    local messages = {}
    for i, msg in ipairs(normalized.messages or {}) do
      local text_parts = {}
      if type(msg.content) == "table" then
        for _, part in ipairs(msg.content) do
          if part.type == "text" then
            text_parts[#text_parts + 1] = part.text or ""
          elseif part.type == "reasoning" then
            text_parts[#text_parts + 1] = ("[reasoning:%d]"):format(#(part.content or ""))
          elseif part.type == "tool_call" then
            text_parts[#text_parts + 1] = ("[tool:%s]"):format(tostring(part.name))
          elseif part.type == "tool_result" then
            text_parts[#text_parts + 1] = ("[tool_result:%s]"):format(tostring(part.status))
          elseif part.type == "image" then
            text_parts[#text_parts + 1] = ("[image:%s]"):format(tostring(part.mime))
          elseif part.type == "context_ref" then
            text_parts[#text_parts + 1] = ("[context:%s]"):format(tostring(part.item_id))
          end
        end
      end
      messages[i] = {
        role = msg.role,
        content = table.concat(text_parts),
      }
    end
    return {
      model = params and params.model or "mock-model",
      provider = self.name,
      messages = messages,
      tools = normalized.tools or {},
    }
  end

  --- Parse a raw stream chunk into a normalized event (unified adapter
  --- `parse_stream`). mock/echo chunks are plain text: each chunk becomes a
  --- `message_delta` event. Real adapters feed SSE frames through the same
  --- signature in W4-W7.
  ---@param frame any raw chunk (string) or normalized envelope table
  ---@return table|nil event normalized event (nil when the frame carries no content)
  function provider.parse_stream(self, frame)
    if type(frame) == "string" then
      if frame == "" then
        return nil
      end
      return normalize.message_delta(frame)
    end
    if type(frame) == "table" and type(frame.type) == "string" and normalize.events[frame.type] then
      -- W8 additive passthrough: an already-normalized event table is delivered
      -- verbatim. This lets headless full-chain tests inject reasoning/tool_call/
      -- usage events through the SAME unified stream surface (mock/echo drive the
      -- UI/smoke path; string chunks keep their exact phase-0 behavior).
      return frame
    end
    if type(frame) == "table" and frame.delta ~= nil then
      return normalize.message_delta(frame.delta)
    end
    return nil
  end

  --- Parse a non-stream response body into a normalized event (unified adapter
  --- `parse_nonstream`). mock/echo mirror the deterministic echo text.
  ---@param body table response body (or request body echo)
  ---@return table event normalized event
  function provider.parse_nonstream(self, body)
    local text = (type(body) == "table" and type(body.text) == "string" and body.text)
      or ("Hello from maxa " .. self.name .. " provider.")
    return normalize.message_delta(text)
  end

  --- Normalize a provider usage object (unified adapter `normalize_usage`).
  --- mock/echo report no provider usage: nil signals the orchestrator to fall
  --- back to a local estimate.
  ---@param raw any provider usage object (unused here)
  ---@return table|nil usage nil (no provider-reported usage)
  function provider.normalize_usage(self, raw)
    return nil
  end

  --- Drive a scripted stream over the unified callback object (unified adapter
  --- `stream`). Raw chunks are converted through parse_stream into normalized
  --- events; when the caller only supplies the legacy on_chunk, raw text is
  --- delivered as-is (backward-compatible driver surface).
  ---@param params table|nil { chunks?, recording?, delay?, error?, error_at?,
  ---                          cancel?, cancel_at?, async? }
  ---@param callbacks table { on_event?=fun(event), on_done?=fun(), on_error?=fun(err) }
  ---@return table handle { active=bool, cancel=fun(on_cancelled?):bool, last_error?=table }
  function provider.stream(self, params, callbacks)
    callbacks = callbacks or {}
    local spec = build_stream_spec(params)
    -- Wrap raw chunks into normalized events unless a legacy on_chunk driver is
    -- the caller (then deliver raw text directly).
    local driver_callbacks = callbacks
    if callbacks.on_event then
      driver_callbacks = {
        on_chunk = function(delta)
          local event = self:parse_stream(delta)
          if event then
            callbacks.on_event(event)
          end
        end,
        on_done = callbacks.on_done,
        on_error = callbacks.on_error,
      }
    end
    return drive_stream(generate_script(spec), driver_callbacks, {
      async = params and params.async,
    })
  end

  return provider
end

------------------------------------------------------------
-- Provider registry / constructors
------------------------------------------------------------

-- Instances cache (singleton per name) for easy reuse in headless/normal usage.
-- Callers that need isolation can call M.new(name) directly.
local instances = {}

--- Real-protocol adapter registry (phase-1 W4-W7 populate). Adapters register
--- under the config protocol enum name (`config.PROTOCOLS`); `config.resolve_provider`
--- binds through `get_adapter`. Until an adapter is registered for a protocol the
--- lookup returns nil and the caller keeps the unbound record (`record:bind`).
--- The local mock/echo adapters are registered under their own names by M.new.
M.adapters = {}

--- Register a protocol adapter instance under its protocol name.
---@param protocol string one of config.PROTOCOLS (openai_chat/openai_responses/anthropic_messages/gemini)
---@param adapter table adapter object (unified adapter interface)
---@return table adapter
function M.register_adapter(protocol, adapter)
  M.adapters[protocol] = adapter
  return adapter
end

--- Get the registered adapter for a protocol name (nil when not yet registered).
---@param protocol string protocol name
---@return table|nil adapter
function M.get_adapter(protocol)
  return M.adapters[protocol]
end

--- Create a fresh provider instance (mock/echo). Also registers the instance
--- under its name so get_adapter("mock")/get_adapter("echo") resolve locally.
---@param name string provider name (M.providers.*)
---@return table provider
function M.new(name)
  assert(
    name == M.providers.mock or name == M.providers.echo,
    ("protocol.new: unknown provider %q (expected mock|echo)"):format(tostring(name))
  )
  local provider = make_provider(name)
  M.adapters[name] = provider
  return provider
end

--- Get the process-wide singleton provider instance.
---@param name string provider name
---@return table provider
function M.get(name)
  if not instances[name] then
    instances[name] = M.new(name)
  end
  return instances[name]
end

--- Recognized provider name list (for config/UI provider selection).
---@return string[]
function M.available()
  return { M.providers.mock, M.providers.echo }
end

-- Provider-type schema validation helper exported for downstream config/test use.
M.validate = schema.validate_field

return M
