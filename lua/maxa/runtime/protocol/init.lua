-- filepath: lua/maxa/runtime/protocol/init.lua
--- maxa runtime protocol layer: mock / echo providers (phase-0 scope).
---
--- Scope (see .supermax/drafts/phase0-development-plan.md §5.5): this phase only
--- ships the mock and echo providers plus the shared provider adapter interface
--- (§4.9). Real four-protocol adapters (OpenAI Chat/Responses, Anthropic Messages,
--- Gemini native) and response normalization belong to phase 1 and are NOT
--- implemented here. `tools/mcp/skills/compat` remain placeholders in other subagents'
--- wave scope; do not implement them here.
---
--- Shared provider interface (§4.9), aligned (read-only) to CodeCompanion's HTTP
--- adapter surface, but self-contained and never loading codecompanion.*:
---
---   provider = {
---     name     = "mock" | "echo",                        -- + future real providers
---     schema   = <schema table: declares model/stream/... params>,  -- validate(setup)
---     setup    = function(self, opts) -> self|err,      -- parse & normalize params
---     map_roles= function(self, messages) -> messages,  -- role/content normalization
---     chat_output = function(self, data, tools) -> lines,-- stream data -> render lines
---     format_data = function(self, data) -> table,      -- stream chunk/SSE parse
---     stream   = function(self, params, callback) -> handle, -- on_chunk/on_done/on_error
---   }
---
---  * stream callback contract: callback is a table/object with the optional
---    three-state callbacks
---      on_chunk(delta):   incremental text delta (string) as it streams
---      on_done():         terminal success (exactly once)
---      on_error(err):     terminal failure, typed error per §4.6; exactly once
---    Exactly one terminal callback (on_done xor on_error) fires per stream.
---  * stream returns a control handle:
---      { cancel = function(cancelled_cb?) -> boolean, active = boolean }
---    invoking handle.cancel() requests an ordered stop: it aborts remaining
---    chunks and, if a terminal callback has not yet fired, fires on_error with a
---    terminal CANCELLED error (exactly once).
---
--- Injection (mock/echo, see §4.9): opts.delay (ms between chunks), opts.error
--- (inject a provider failure exactly once after opts.error_at chunks), opts.cancel
--- (auto-cancel after opts.error_at chunks). Recording mode (opts.recording) replays
--- a captured chunk sequence deterministically for headless/floating verification.
---
--- Topology: schema -> protocol. This module depends only on
--- lua/maxa/runtime/schema (for typed errors + usage shape). It never loads
--- codecompanion.* / mcphub.* / lua/util/hooks/*.

local schema = require("maxa.runtime.schema")

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

--- Provider name constants (future real adapters register here in phase 1).
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

--- Provider factory. Both `mock` and `echo` share this base so their interfaces
--- stay identical (future real providers conform to the same surface).
---@param name "mock"|"echo"
---@return table provider object
local function make_provider(name)
  local provider = {}

  provider.name = name
  -- Declared setup schema (subset of §4.9: model/stream options). Phase 0 keeps it
  -- minimal; phase 1 expands with real adapter parameters.
  provider.schema = {
    model = { type = "string", optional = true, default = "mock-model" },
    delay = { type = "integer", optional = true, default = 0 },
    -- normalized parameters set by setup(); recorded for callers/telemetry.
    _params = { type = "map", optional = true, default = nil },
  }

  --- Parse and normalize params; returns normalized params, or nil+error on
  --- validation failure (§4.9 setup).
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

  --- Role/content normalization (§4.9 map_roles). mock/echo pass through role as-is
  --- (single normalized role space in phase 0); real adapters map to provider roles.
  ---@param messages table normalized message list
  ---@return table normalized messages (identity-equal pass-through)
  function provider.map_roles(self, messages)
    return messages
  end

  --- Render a stream data piece to chat display lines (§4.9 chat_output).
  --- mock/echo: a single text chunk renders as one line entry.
  ---@param data string|table chunk or formatted data shape
  ---@return table lines array of render line strings
  function provider.chat_output(self, data, tools)
    local text = type(data) == "string" and data or (data and data.delta) or ""
    if text == "" then
      return {}
    end
    return { text }
  end

  --- Parse a raw stream chunk into a normalized shape (§4.9 format_data).
  --- mock/echo produce a simple `{ delta = <string> }` envelope; real SSE parsers
  --- in phase 1 normalize events to this same envelope.
  ---@param data any raw chunk
  ---@return table { delta=string }
  function provider.format_data(self, data)
    if type(data) == "string" then
      return { delta = data }
    end
    return { delta = (data and data.delta) or "" }
  end

  --- Drive a scripted stream over a callback object (§4.9 stream).
  ---@param params table|nil { chunks?, recording?, delay?, error?, error_at?,
  ---                          cancel?, cancel_at?, async? }
  ---@param callback table { on_chunk?=fun(delta), on_done?=fun(), on_error?=fun(err) }
  ---@return table handle { active=bool, cancel=fun(on_cancelled?):bool, last_error?=table }
  function provider.stream(self, params, callback)
    local spec = build_stream_spec(params)
    return drive_stream(generate_script(spec), callback, {
      async = params and params.async,
    })
  end

  return provider
end

------------------------------------------------------------
-- Provider registry / constructors
------------------------------------------------------------

--- Instances cache (singleton per name) for easy reuse in headless/normal usage.
--- Callers that need isolation can call M.new(name) directly.
local instances = {}

--- Create a fresh provider instance.
---@param name string provider name (M.providers.*)
---@return table provider
function M.new(name)
  assert(
    name == M.providers.mock or name == M.providers.echo,
    ("protocol.new: unknown provider %q (expected mock|echo)"):format(tostring(name))
  )
  return make_provider(name)
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
