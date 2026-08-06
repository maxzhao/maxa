-- filepath: lua/maxa/runtime/status/init.lua
--- Status service (phase-5 W2): subscribes the event bus, applies the immutable
--- spine reducer on every event, and notifies `on_refresh` observers AFTER the
--- snapshot is updated (querying snapshot() immediately observes the new
--- revision). Pure of CodeCompanion internals: lualine/UI consumers read only
--- the spine snapshot and normalized usage/billing projections.
---
--- API:
---   new({ events, config }) -> service (not started)
---   svc:start()             -> subscribe the bus; returns self
---   svc:dispose()           -> unsubscribe (idempotent)
---   svc:snapshot()          -> current immutable snapshot reference
---   svc:on_refresh(cb)      -> register an observer (failure-isolated)
---   svc:reconcile(views)    -> repair stale running sessions (views =
---                              { { session_id, busy } }); records diagnostics
---   svc:set_display_session(id) -> update display identity (independent of
---                              the active session identity)
---   svc:spinner_phase(now_ms?) -> deterministic phase for the current snapshot
---   svc:spinner_delay()     -> configured debounce (default 300ms)
---   svc:billing_snapshot()  -> typed quota projection (never raises)
---
--- Config reading is defensive (`cfg.ui and cfg.ui.spinner_delay`,
--- `cfg.status and cfg.status.billing`): missing config sections or fields
--- fall back to safe defaults without requiring new config keys.

local spine = require("maxa.runtime.status.spine")
local billing = require("maxa.runtime.status.billing")

local M = {}

M.name = "status"

---@private Copy of the immutable snapshot; replaced atomically on every applied
--- event. External readers keep the reference they fetched (never mutated).
---@param opts table { events = table bus, config = table|nil }
---@return table service
function M.new(opts)
  opts = opts or {}
  local cfg = opts.config or {}
  local svc = {
    events = opts.events,
    config = cfg,
    _snapshot = spine.initial_snapshot(),
    _subs = {}, -- unsubscribe functions
    _refresh = {}, -- on_refresh observers
    _started = false,
    _reconcile_log = {},
  }

  --- Notify observers AFTER state update; each callback is failure-isolated.
  ---@private
  local function notify_refresh()
    for _, cb in ipairs(svc._refresh) do
      local ok, err = pcall(cb, svc._snapshot)
      if not ok then
        svc._reconcile_log[#svc._reconcile_log + 1] = {
          kind = "refresh_callback_failed",
          error = tostring(err),
        }
      end
    end
  end

  --- Apply an envelope through the reducer; refresh observers on change.
  ---@private
  ---@param envelope table
  local function apply(envelope)
    local next_snapshot = spine.reducer(svc._snapshot, envelope)
    if next_snapshot ~= svc._snapshot then
      svc._snapshot = next_snapshot
      notify_refresh()
    end
  end

  --- Subscribe every bus event name the reducer understands (string match is
  --- done inside the reducer; the service subscribes a single wildcard-style
  --- callback per known event for clarity).
  ---@private
  local EVENT_NAMES = {
    "request.started",
    "response.started",
    "usage.updated",
    "tool_call.started",
    "tool_call.delta",
    "tool_call.completed",
    "tool_batch.started",
    "response.completed",
    "response.failed",
    "response.cancelled",
    "continuation.decided",
    "watchdog.retry",
    "chat.soft_stop_requested",
    "chat.soft_stop_completed",
    "chat.closed",
    "mcp.server_state",
  }

  --- Subscribe the bus (idempotent).
  ---@return table self
  function svc:start()
    if svc._started then
      return self
    end
    svc._started = true
    for _, name in ipairs(EVENT_NAMES) do
      local off
      off = svc.events.on(name, function(payload, envelope)
        apply(envelope)
      end)
      svc._subs[#svc._subs + 1] = off
    end
    return self
  end

  --- Unsubscribe the bus and drop observers (idempotent).
  ---@return table self
  function svc:dispose()
    for _, off in ipairs(svc._subs) do
      pcall(off)
    end
    svc._subs = {}
    svc._refresh = {}
    svc._started = false
    return self
  end

  ---@return table immutable snapshot (reference; never mutated by the service)
  function svc:snapshot()
    return svc._snapshot
  end

  --- Register a refresh observer: called with the new snapshot after every
  --- applied event. Failures are isolated and recorded, never propagated.
  ---@param cb function callback(snapshot)
  ---@return function unregister
  function svc:on_refresh(cb)
    svc._refresh[#svc._refresh + 1] = cb
    local registered = true
    return function()
      if not registered then
        return
      end
      registered = false
      for i = #svc._refresh, 1, -1 do
        if svc._refresh[i] == cb then
          table.remove(svc._refresh, i)
        end
      end
    end
  end

  --- Reconcile against live owned views after restore: views is a list of
  --- { session_id, busy } records. Stale running sessions (not live or not
  --- busy) are closed; the diagnostic is recorded and exposed via
  --- reconcile_log(). Applies through the reducer (new snapshot, revision+1).
  ---@param views table[] list of { session_id=string, busy=boolean }
  ---@return table new snapshot
  function svc:reconcile(views)
    local envelope = {
      event = spine.RECONCILE_EVENT,
      payload = { views = views or {}, at = os.time() * 1000 },
      emitted_at = os.time() * 1000,
    }
    apply(envelope)
    local stale = svc._snapshot._reconcile.stale or {}
    if #stale > 0 then
      svc._reconcile_log[#svc._reconcile_log + 1] = {
        kind = "reconcile",
        stale = stale,
        at = svc._snapshot._reconcile.at,
      }
    end
    return svc._snapshot
  end

  --- Update the display session identity (independent of active identity).
  --- Applies through the reducer path so revision stays monotonic.
  ---@param session_id string|nil
  ---@return table new snapshot
  function svc:set_display_session(session_id)
    local envelope = {
      event = "spine.set_display_session",
      payload = { session_id = session_id },
      emitted_at = os.time() * 1000,
    }
    -- The reducer has no bus event for display identity; the service owns this
    -- field directly through the same immutable-replace discipline.
    local s = {}
    for k, v in pairs(svc._snapshot) do
      s[k] = v
    end
    s.display_session_id = (type(session_id) == "string" and session_id) or nil
    s.revision = (svc._snapshot.revision or 0) + 1
    svc._snapshot = s
    notify_refresh()
    return svc._snapshot
  end

  --- Deterministic spinner phase for the current snapshot.
  ---@param now_ms integer|nil clock time (default vim.uv.hrtime/1e6 when nvim
  ---   is available, else os.time()*1000)
  ---@return string phase (spine.PHASES value)
  function svc:spinner_phase(now_ms)
    local now = now_ms
    if now == nil then
      if vim and vim.uv and vim.uv.hrtime then
        now = math.floor(vim.uv.hrtime() / 1e6)
      else
        now = os.time() * 1000
      end
    end
    return spine.spinner_phase(svc._snapshot, now, svc:spinner_delay())
  end

  ---@return integer configured spinner debounce (default 300ms)
  function svc:spinner_delay()
    local delay = svc.config and svc.config.ui and svc.config.ui.spinner_delay
    return (type(delay) == "number" and delay > 0 and delay) or spine.DEFAULT_SPINNER_DELAY
  end

  --- Typed quota/billing projection for the current usage. Never raises.
  ---@return table typed projection (billing.snapshot contract)
  function svc:billing_snapshot()
    local status_cfg = svc.config and svc.config.status
    local billing_cfg = status_cfg and status_cfg.billing
    if not billing_cfg or billing_cfg.enabled ~= true then
      return { available = false, enabled = false }
    end
    return billing.snapshot(billing_cfg.provider, svc._snapshot.usage)
  end

  --- Reconcile diagnostics (test/diagnostic surface).
  ---@return table[] log entries
  function svc:reconcile_log()
    return svc._reconcile_log
  end

  return svc
end

return M
