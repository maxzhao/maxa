-- filepath: tests/state/lib/recorder.lua
--- Event recorder for R-STATE fixtures (phase 2 W2 test base). Test-only.
---
--- Collects every bus emission in order: event name + payload + envelope
--- (sequence/emitted_at), with an optional name filter. The default skip list
--- drops "session.created" (emitted once per session construction, before the
--- per-request event sequences that fixtures assert).
---
--- Usage:
---   local rec = recorder.new({ skip = { "session.created" } })
---   rec.attach(bus)
---   ... run the scenario ...
---   rec.names / rec.items / rec.count(name) / rec.names_concat()

local M = {}

---@param opts? table {
---   skip?: string[] event names to ignore (default { "session.created" }),
---   filter?: fun(name: string): boolean|nil custom allow filter (wins over skip)
--- }
---@return table rec
function M.new(opts)
  opts = opts or {}
  local skip = {}
  local default_skip = opts.filter == nil
  for _, name in ipairs(opts.skip or { "session.created" }) do
    skip[name] = true
  end

  local rec = {
    items = {}, -- ordered { event=string, payload=table, envelope=table }
    names = {}, -- ordered event names (filtered)
  }

  --- Subscribe to every known event name on a bus (from bus.events).
  --- Returns a detach function that removes all subscriptions.
  ---@param bus table event bus (events.new() instance or the global module)
  ---@return function detach
  function rec.attach(bus)
    local offs = {}
    for key, name in pairs(bus.events or {}) do
      if type(key) == "string" then
        local allowed
        if opts.filter then
          allowed = opts.filter(name)
        else
          allowed = not skip[name]
        end
        if allowed then
          local off = bus.on(name, function(payload, envelope)
            rec.items[#rec.items + 1] = { event = name, payload = payload, envelope = envelope }
            rec.names[#rec.names + 1] = name
          end)
          offs[#offs + 1] = off
        end
      end
    end
    return function()
      for _, off in ipairs(offs) do
        off()
      end
    end
  end

  ---@param name string event name
  ---@return integer number of recorded emissions for name
  function rec.count(name)
    local n = 0
    for _, ev in ipairs(rec.names) do
      if ev == name then
        n = n + 1
      end
    end
    return n
  end

  ---@return string comma-joined recorded event names (order preserved)
  function rec.names_concat()
    return table.concat(rec.names, ",")
  end

  --- Reset the recorded list (subscriptions stay attached).
  function rec.clear()
    rec.items = {}
    rec.names = {}
  end

  return rec
end

return M
