-- filepath: tests/actions/lib/mock_context.lua
--- Phase-5 W4 programmable dispatch-context mock for the actions suite.
---
--- Exposes the builtin capability interface (actions/builtin.lua contract):
---   * request_busy: boolean busy flag
---   * set_provider(name) / set_model(model) / clear() / close_session()
---   * request_control: { stop(), soft_stop(), context_stop(target) }
---   * view_control: { hide(), reattach(), close_view() }
---   * history: { save, list, open, fork, scratch, merge, transfer, rewind,
---                redo, compact, trace }
---   * spine_snapshot() / config()
---
--- Capabilities are enabled by default and record every call into
--- `ctx.calls` (ordered { name, args }). Options disable (`false`), override
--- (`function`) or inject sub-object overrides (`table`) per capability:
---   mock.new({ history = { save = function(self, args, opts) ... end } })
---
--- `ctx.calls_for(name)` filters the call log; `ctx.reset_calls()` clears it.

local M = {}

local CONTROL_METHODS = { "stop", "soft_stop", "context_stop" }
local VIEW_METHODS = { "hide", "reattach", "close_view" }
local HISTORY_METHODS = {
  "save",
  "list",
  "open",
  "fork",
  "scratch",
  "merge",
  "transfer",
  "rewind",
  "redo",
  "compact",
  "trace",
}

--- Create a fresh mock context.
---@param opts? table {
---   request_busy?: boolean default false
---   set_provider/set_model/clear/close_session/spine_snapshot/config?:
---     false disables, function overrides, nil/true uses the recording default
---   request_control/view_control/history?: false disables, table overrides
---     individual methods, nil/true uses recording defaults
---   snapshot?: table spine snapshot returned by spine_snapshot()
---   cfg?: table config returned by config()
--- }
---@return table ctx
function M.new(opts)
  opts = opts or {}
  local ctx = {
    request_busy = not not opts.request_busy,
    calls = {}, -- ordered { name=string, args=table }
    name = "mock_context",
  }

  local function record(name, ...)
    ctx.calls[#ctx.calls + 1] = { name = name, args = { ... } }
  end

  ---@param name string capability call name
  ---@return table[] matching calls
  function ctx.calls_for(name)
    local out = {}
    for _, call in ipairs(ctx.calls) do
      if call.name == name then
        out[#out + 1] = call
      end
    end
    return out
  end

  function ctx.reset_calls()
    ctx.calls = {}
  end

  --- Install a flat capability: false disables, function overrides, otherwise
  --- the recording default is used.
  local function install(name, default)
    local v = opts[name]
    if v == false then
      return
    end
    if type(v) == "function" then
      ctx[name] = v
    else
      ctx[name] = default
    end
  end

  install("set_provider", function(self, provider)
    record("set_provider", provider)
    return true
  end)
  install("set_model", function(self, model)
    record("set_model", model)
    return true
  end)
  install("clear", function(self)
    record("clear")
    return true
  end)
  install("close_session", function(self)
    record("close_session")
    return true
  end)

  -- request_control capability.
  if opts.request_control ~= false then
    local overrides = type(opts.request_control) == "table" and opts.request_control or {}
    ctx.request_control = {}
    for _, method in ipairs(CONTROL_METHODS) do
      ctx.request_control[method] = overrides[method]
        or function(self, arg)
          record("request_control." .. method, arg)
          return true
        end
    end
  end

  -- view_control capability.
  if opts.view_control ~= false then
    local overrides = type(opts.view_control) == "table" and opts.view_control or {}
    ctx.view_control = {}
    for _, method in ipairs(VIEW_METHODS) do
      ctx.view_control[method] = overrides[method]
        or function(self)
          record("view_control." .. method)
          return true
        end
    end
  end

  -- history capability.
  if opts.history ~= false then
    local overrides = type(opts.history) == "table" and opts.history or {}
    ctx.history = {}
    for _, method in ipairs(HISTORY_METHODS) do
      ctx.history[method] = overrides[method]
        or function(self, args, hopts)
          record("history." .. method, args, hopts)
          return { ok = true }
        end
    end
  end

  install("spine_snapshot", function(self)
    record("spine_snapshot")
    return opts.snapshot or { provider = "mock", model = "mock-model", status = "idle", busy = false }
  end)

  install("config", function(self)
    record("config")
    return opts.cfg or { providers = { mock = { protocol = "mock" } } }
  end)

  return ctx
end

return M
