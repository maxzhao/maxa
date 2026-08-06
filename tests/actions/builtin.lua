-- filepath: tests/actions/builtin.lua
--- Phase-5 W4 built-in family fixtures: full registration + idempotency, full
--- dispatch against a mock context (capability calls recorded), busy rejection
--- for requires_idle_request builtins, missing capability -> unavailable,
--- status.panel formatting, health.check output, history args/opts forwarding
--- and capability-throw -> handler_error.

local assert_mod = require("tests.actions.lib.assert")
local mock = require("tests.actions.lib.mock_context")
local actions = require("maxa.runtime.actions")
local builtin = require("maxa.runtime.actions.builtin")

local a = assert_mod.new()

local EXPECTED_IDS = {
  "chat.provider",
  "chat.model",
  "chat.stop",
  "chat.soft_stop",
  "chat.context_stop",
  "chat.clear",
  "view.hide",
  "view.reattach",
  "view.close_view",
  "view.close_session",
  "history.save",
  "history.list",
  "history.open",
  "history.fork",
  "history.scratch",
  "history.merge",
  "history.transfer",
  "history.rewind",
  "history.redo",
  "history.compact",
  "history.trace",
  "status.panel",
  "health.check",
}
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

--- Minimal valid input per builtin input_schema (most builtins accept {}).
local function default_input(id)
  if id == "chat.provider" then
    return { name = "mock" }
  end
  if id == "chat.model" then
    return { model = "mock-model" }
  end
  if id == "chat.context_stop" then
    return { target = "70%" }
  end
  return {}
end

-- 1. register_all registers the full built-in family.
local reg = actions.new()
a.check(builtin.register_all(reg) == reg, "builtin: register_all returns the registry")
local items = reg:list()
a.check(#items == #EXPECTED_IDS, "builtin: full family registered (" .. #items .. "/" .. #EXPECTED_IDS .. ")")
a.check(items[1].handler == nil and items[1].condition == nil, "builtin: public items expose no handler/condition")
local ids = {}
for _, it in ipairs(items) do
  ids[it.id] = true
end
for _, id in ipairs(EXPECTED_IDS) do
  a.check(ids[id] == true, "builtin: registered " .. id)
end

-- 2. register_all is idempotent (same definition hashes).
local ok2, err2 = pcall(builtin.register_all, reg)
a.check(ok2, "builtin: register_all idempotent (" .. tostring(err2) .. ")")

-- 3. full dispatch against a full mock context.
local ctx = mock.new()
local all_ok = true
for _, id in ipairs(EXPECTED_IDS) do
  local res = reg:dispatch(id, default_input(id), ctx)
  if not (res.ok == true) then
    all_ok = false
    a.check(false, "builtin: dispatch " .. id .. " failed (" .. vim.inspect(res) .. ")")
  end
end
a.check(all_ok, "builtin: all builtins dispatch with full mock context")

-- 4. every capability call was recorded exactly once.
a.check(#ctx.calls_for("set_provider") == 1, "builtin: set_provider called once")
a.check(#ctx.calls_for("set_model") == 1, "builtin: set_model called once")
a.check(#ctx.calls_for("request_control.stop") == 1, "builtin: request_control.stop called once")
a.check(#ctx.calls_for("request_control.soft_stop") == 1, "builtin: request_control.soft_stop called once")
local cs = ctx.calls_for("request_control.context_stop")
a.check(#cs == 1 and cs[1].args[1] == "70%", "builtin: request_control.context_stop called with target")
a.check(#ctx.calls_for("clear") == 1, "builtin: clear called once")
a.check(#ctx.calls_for("view_control.hide") == 1, "builtin: view_control.hide called once")
a.check(#ctx.calls_for("view_control.reattach") == 1, "builtin: view_control.reattach called once")
a.check(#ctx.calls_for("view_control.close_view") == 1, "builtin: view_control.close_view called once")
a.check(#ctx.calls_for("close_session") == 1, "builtin: close_session called once")
for _, method in ipairs(HISTORY_METHODS) do
  a.check(#ctx.calls_for("history." .. method) == 1, "builtin: history." .. method .. " called once")
end
a.check(#ctx.calls_for("spine_snapshot") == 1, "builtin: spine_snapshot called once")
a.check(#ctx.calls_for("config") == 1, "builtin: config called once")

-- 5. requires_idle_request builtins reject a busy context.
local busy_ctx = mock.new({ request_busy = true })
local bres = reg:dispatch("chat.provider", { name = "mock" }, busy_ctx)
a.check(bres.ok == false and bres.code == "busy", "builtin: chat.provider busy -> busy")
local bres2 = reg:dispatch("chat.model", { model = "m" }, busy_ctx)
a.check(bres2.ok == false and bres2.code == "busy", "builtin: chat.model busy -> busy")

-- 6. missing capability -> typed unavailable result (dispatch-level ok).
local bare = {} -- no capabilities at all
for _, id in ipairs(EXPECTED_IDS) do
  local res = reg:dispatch(id, default_input(id), bare)
  a.check(
    res.ok == true and res.result and res.result.ok == false and res.result.code == "unavailable",
    "builtin: " .. id .. " missing capability -> unavailable (got " .. vim.inspect(res) .. ")"
  )
end

-- 7. status.panel formats a spine snapshot into read-only text lines.
local snap_ctx = mock.new({ snapshot = { provider = "mock", model = "m1", status = "idle" } })
local sres = reg:dispatch("status.panel", {}, snap_ctx)
local spanel = sres.result -- handler result: { ok=true, result={ lines, text } }
a.check(
  sres.ok == true and type(spanel) == "table" and spanel.ok == true and type(spanel.result) == "table",
  "builtin: status.panel handler result ok"
)
a.check(
  type(spanel.result.lines) == "table" and type(spanel.result.text) == "string",
  "builtin: status.panel returns formatted lines+text (got " .. vim.inspect(spanel) .. ")"
)
a.check(#spanel.result.lines >= 3, "builtin: status.panel lines count (" .. #spanel.result.lines .. ")")
a.check(spanel.result.text:find("provider: mock", 1, true) ~= nil, "builtin: status.panel text includes snapshot keys")

-- 8. health.check produces checkhealth-style lines covering runtime+config.
local hres = reg:dispatch("health.check", {}, mock.new())
local hpanel = hres.result -- handler result: { ok=true, result={ lines, text } }
a.check(hres.ok == true and hpanel and hpanel.ok == true and type(hpanel.result.lines) == "table", "builtin: health.check returns lines")
local htext = table.concat(hpanel.result.lines, "\n")
a.check(htext:find("maxa runtime", 1, true) ~= nil, "builtin: health.check covers runtime (" .. htext .. ")")
a.check(htext:find("config", 1, true) ~= nil, "builtin: health.check covers config")

-- 9. history handlers forward args+opts to the context.history service.
local hist = {}
local hist_ctx = mock.new({
  history = {
    save = function(self, args, opts)
      hist.save = { args = args, opts = opts }
      return { ok = true, save_id = "s1" }
    end,
    list = function()
      return { ok = true, entries = {} }
    end,
    open = function()
      return { ok = true }
    end,
    fork = function()
      return { ok = true }
    end,
    scratch = function()
      return { ok = true }
    end,
    merge = function()
      return { ok = true }
    end,
    transfer = function()
      return { ok = true }
    end,
    rewind = function()
      return { ok = true }
    end,
    redo = function()
      return { ok = true }
    end,
    compact = function()
      return { ok = true }
    end,
    trace = function()
      return { ok = true }
    end,
  },
})
local hsave = reg:dispatch("history.save", { args = { session_id = "x" }, opts = { save_id = "custom" } }, hist_ctx)
a.check(
  hsave.ok == true and hsave.result.ok == true and hsave.result.result.ok == true and hsave.result.result.save_id == "s1",
  "builtin: history.save dispatches through context.history (got " .. vim.inspect(hsave) .. ")"
)
a.check(
  hist.save and hist.save.args.session_id == "x" and hist.save.opts.save_id == "custom",
  "builtin: history.save forwards args+opts"
)

-- 10. capability throw -> typed handler_error result (dispatch-level ok).
local throw_ctx = mock.new({
  set_provider = function()
    error("boom")
  end,
})
local tres = reg:dispatch("chat.provider", { name = "mock" }, throw_ctx)
a.check(
  tres.ok == true and tres.result and tres.result.ok == false and tres.result.code == "handler_error",
  "builtin: capability throw -> handler_error typed result (got " .. vim.inspect(tres) .. ")"
)

if not a.ok then
  error("BUILTIN_FIXTURE_FAILED: " .. table.concat(a.failures, "; "))
end
print("BUILTIN_FIXTURE_OK")
