-- filepath: lua/maxa/runtime/clock.lua
--- maxa runtime deterministic clock contract (phase 2 W2).
---
--- Scope: defines the injectable clock seam used by session (transition stamps),
--- events (envelope emitted_at) and future timer-driven modules (watchdog W7,
--- continuation scheduling W5). Runtime modules accept an optional `opts.clock`
--- and default to `clock.default()`; tests inject a fake clock
--- (tests/state/lib/fake_clock.lua) for deterministic fixtures.
---
--- Clock contract (implemented by both the default and the fake clock):
---   clock.now_ms()                  -> integer   monotonic milliseconds
---   clock.schedule(delay_ms, cb)    -> handle    run cb once after delay_ms;
---                                                handle supports cancel_timer
---   clock.cancel_timer(handle)                 -> void; idempotent, safe for
---                                                already-fired handles
---
--- The default implementation is backed by vim.uv (hrtime + new_timer) so
--- timers are real and cancelable. This module never loads codecompanion.* /
--- mcphub.* / lua/util/hooks/*.

local M = {}

M.name = "clock"

--- Wall-clock milliseconds via vim.uv.hrtime (monotonic where available).
---@return integer
local function default_now_ms()
  if vim and vim.uv and vim.uv.hrtime then
    return math.floor(vim.uv.hrtime() / 1e6)
  end
  return os.time() * 1000
end

--- Build the default (real) clock. A fresh table is returned per call so
--- callers never share mutable timer state by accident; the timer handles are
--- per-schedule and fully cancelable.
---@return table clock { now_ms, schedule, cancel_timer }
function M.default()
  return {
    now_ms = default_now_ms,
    --- Schedule a one-shot callback after delay_ms (>=0). Returns a handle
    --- accepted by cancel_timer. The callback runs on the event loop in a
    --- normal (scheduled) context, matching vim.defer_fn semantics.
    ---@param delay_ms integer
    ---@param cb function
    ---@return table handle
    schedule = function(delay_ms, cb)
      local handle = { cancelled = false, timer = nil }
      local function fire()
        if handle.cancelled then
          return
        end
        handle.cancelled = true
        pcall(cb)
      end
      if vim and vim.uv and vim.uv.new_timer then
        local timer = vim.uv.new_timer()
        handle.timer = timer
        timer:start(math.max(0, delay_ms or 0), 0, vim.schedule_wrap(fire))
      elseif vim and vim.defer_fn then
        -- Defensive fallback (no uv): defer_fn handles are not cancelable; the
        -- cancelled flag still prevents the callback body from running.
        vim.defer_fn(fire, math.max(0, delay_ms or 0))
      else
        error("clock.default.schedule: no timer backend available (vim.uv/vim.defer_fn)", 0)
      end
      return handle
    end,
    --- Cancel a pending scheduled callback. Idempotent; a handle whose
    --- callback already fired is a no-op.
    ---@param handle table handle from schedule
    cancel_timer = function(handle)
      if not handle or handle.cancelled then
        return
      end
      handle.cancelled = true
      if handle.timer then
        pcall(handle.timer.stop, handle.timer)
        pcall(handle.timer.close, handle.timer)
        handle.timer = nil
      end
    end,
  }
end

return M
