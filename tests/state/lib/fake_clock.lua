-- filepath: tests/state/lib/fake_clock.lua
--- Deterministic fake clock for R-STATE fixtures (phase 2 W2 test base).
--- Test-only; never required from the runtime (runtime default clock lives in
--- lua/maxa/runtime/clock.lua).
---
--- Implements the same contract as clock.default():
---   fake.now_ms()                  -> integer virtual now (ms)
---   fake.schedule(delay_ms, cb)    -> handle (due = now + delay_ms)
---   fake.cancel_timer(handle)      -> cancel and REMOVE from the pending queue;
---                                    never fires afterwards (pending()/idle()
---                                    count only active timers, matching the
---                                    "active timer count" contract)
---
--- Plus deterministic drivers:
---   fake.advance(ms)               -> now += ms, then fire every timer due
---                                     <= new now in (due, registration) order;
---                                     reentrant schedules due within the same
---                                     advance also fire (loop until quiescent)
---   fake.run_due()                 -> fire all timers due <= now without moving
---                                     now (zero-delay timers after advance(0))
---   fake.pending() / fake.idle()   -> active timer count / no pending timers
---   fake.remaining()               -> ms until the next due timer (or nil)
---   fake.fired_count()             -> total callbacks fired (diagnostic)
---
--- Firing order is deterministic: timers fire by (due time, registration id),
--- matching uv timer semantics. A failing callback aborts the fixture loudly.

local M = {}

---@param opts? table { now = integer|nil } initial virtual time in ms (default 0)
---@return table fake
function M.new(opts)
  opts = opts or {}
  local state = {
    now = opts.now or 0,
    timers = {}, -- sorted by (due, id)
    seq = 0,
    fired = 0,
  }

  local fake = {}

  function fake.now_ms()
    return state.now
  end

  --- Schedule a one-shot callback; returns a cancelable handle.
  ---@param delay_ms integer
  ---@param cb function
  ---@return table handle
  function fake.schedule(delay_ms, cb)
    assert(type(cb) == "function", "fake_clock.schedule: cb must be a function")
    state.seq = state.seq + 1
    local handle = {
      id = state.seq,
      due = state.now + math.max(0, delay_ms or 0),
      cb = cb,
      cancelled = false,
    }
    local inserted = false
    for i, t in ipairs(state.timers) do
      if t.due > handle.due or (t.due == handle.due and t.id > handle.id) then
        table.insert(state.timers, i, handle)
        inserted = true
        break
      end
    end
    if not inserted then
      state.timers[#state.timers + 1] = handle
    end
    return handle
  end

  --- Cancel a pending timer (idempotent; fired timers are unaffected). The
  --- handle is also REMOVED from the pending queue so pending()/idle() reflect
  --- only active timers (a cancelled timer never fires and is not pending).
  ---@param handle table handle from schedule
  function fake.cancel_timer(handle)
    if not handle or handle.cancelled then
      return
    end
    handle.cancelled = true
    for i, t in ipairs(state.timers) do
      if t == handle then
        table.remove(state.timers, i)
        break
      end
    end
  end

  --- Advance the virtual clock and fire all timers now due. Reentrant
  --- schedules due within the same advance are also fired.
  ---@param ms integer
  ---@return integer new virtual now
  function fake.advance(ms)
    state.now = state.now + math.max(0, ms or 0)
    fake.run_due()
    return state.now
  end

  --- Fire every timer due <= now without advancing the clock.
  ---@return integer number of callbacks fired
  function fake.run_due()
    local fired = 0
    while true do
      local t = state.timers[1]
      if not t or t.due > state.now then
        break
      end
      table.remove(state.timers, 1)
      if not t.cancelled then
        state.fired = state.fired + 1
        fired = fired + 1
        local ok, err = pcall(t.cb)
        if not ok then
          error(("fake_clock: timer callback #%d failed: %s"):format(t.id, tostring(err)), 0)
        end
      end
    end
    return fired
  end

  ---@return integer number of active (pending) timers
  function fake.pending()
    return #state.timers
  end

  ---@return boolean true when no timers are pending
  function fake.idle()
    return #state.timers == 0
  end

  ---@return integer|nil ms until the next due timer (nil when idle)
  function fake.remaining()
    local t = state.timers[1]
    return t and t.due - state.now or nil
  end

  ---@return integer total callbacks fired so far
  function fake.fired_count()
    return state.fired
  end

  return fake
end

return M
