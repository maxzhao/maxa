-- filepath: lua/maxa/runtime/actions/builtin.lua
--- Phase-5 W4 built-in action/command family.
---
--- `register_all(registry)` registers the built-in operations. Handlers never
--- hold runtime module references at registration time; they interact with the
--- dispatch context through capability interfaces:
---   * context.set_provider(name) / context.set_model(model)
---   * context.request_control: { stop(), soft_stop(), context_stop(target) }
---   * context.clear()
---   * context.view_control: { hide(), reattach(), close_view() }
---   * context.close_session()
---   * context.history: { save, list, open, fork, scratch, merge, transfer,
---                        rewind, redo, compact, trace }
---   * context.spine_snapshot()   (status.panel)
---   * context.config()           (health.check)
---
--- Capability semantics (typed operation-level results):
---   * missing capability -> { ok=false, code="unavailable", error=... }
---   * capability call throws -> { ok=false, code="handler_error", error=... }
---   * capability returns -> { ok=true, result=<capability result> }
---
--- These are handler results returned through the registry dispatch contract,
--- so the Chat/request state is never locked by a failed built-in.

local M = {}

--- Invoke a context capability.
---@param ctx table|nil dispatch context
---@param parent string|nil capability table name (nil = context itself)
---@param method string method name
---@param arg any single argument forwarded to the capability
---@return string status "ok" | "missing" | "threw"
---@return any result, or error detail when not "ok"
local function cap_call(ctx, parent, method, arg)
  if type(ctx) ~= "table" then
    return "missing", "context missing"
  end
  local target = ctx
  if parent then
    target = ctx[parent]
    if type(target) ~= "table" then
      return "missing", ("context.%s unavailable"):format(parent)
    end
  end
  local fn = target[method]
  if type(fn) ~= "function" then
    return "missing", ("context.%s%s unavailable"):format(parent and (parent .. ".") or "", method)
  end
  local ok, res = pcall(fn, target, arg)
  if not ok then
    return "threw", tostring(res)
  end
  return "ok", res
end

--- Handler factory for a single-capability operation.
---@param parent string|nil capability table name
---@param method string capability method
---@param arg_field string|nil input field forwarded as the capability argument
---@return function handler(input, context)
local function simple_handler(parent, method, arg_field)
  return function(input, context)
    input = input or {}
    local status, res = cap_call(context, parent, method, arg_field and input[arg_field] or nil)
    if status == "missing" then
      return { ok = false, code = "unavailable", error = res }
    end
    if status == "threw" then
      return { ok = false, code = "handler_error", error = res }
    end
    return { ok = true, result = res }
  end
end

--- Handler factory for history operations (payload/opts forwarding).
---@param method string history service method name
---@return function handler(input, context)
local function history_handler(method)
  return function(input, context)
    input = input or {}
    local h = context and context.history
    if type(h) ~= "table" or type(h[method]) ~= "function" then
      return { ok = false, code = "unavailable", error = ("context.history.%s unavailable"):format(method) }
    end
    local ok, res = pcall(h[method], h, input.args, input.opts)
    if not ok then
      return { ok = false, code = "handler_error", error = tostring(res) }
    end
    return { ok = true, result = res }
  end
end

--- status.panel: read-only formatted text projection over the spine snapshot.
---@return table typed result { ok=true, result={ lines=string[], text=string } }
local function status_panel_handler(input, context)
  if type(context) ~= "table" or type(context.spine_snapshot) ~= "function" then
    return { ok = false, code = "unavailable", error = "context.spine_snapshot unavailable" }
  end
  local ok, snap = pcall(context.spine_snapshot, context)
  if not ok then
    return { ok = false, code = "handler_error", error = tostring(snap) }
  end
  snap = snap or {}
  local lines = { "maxa status" }
  local keys = {}
  for k in pairs(snap) do
    if type(k) == "string" then
      keys[#keys + 1] = k
    end
  end
  table.sort(keys)
  for i, k in ipairs(keys) do
    local v = snap[k]
    local marker = i == #keys and "└─" or "├─"
    local val = type(v) == "table" and vim.inspect(v) or tostring(v)
    lines[#lines + 1] = marker .. " " .. k .. ": " .. val
  end
  return { ok = true, result = { lines = lines, text = table.concat(lines, "\n") } }
end

--- health.check: checkhealth-style plain-text line array covering runtime
--- module inventory, config validity and provider availability.
---@return table typed result { ok=true, result={ lines=string[], text=string } }
local function health_check_handler(input, context)
  if type(context) ~= "table" or type(context.config) ~= "function" then
    return { ok = false, code = "unavailable", error = "context.config unavailable" }
  end
  local ok, cfg = pcall(context.config, context)
  if not ok then
    return { ok = false, code = "handler_error", error = tostring(cfg) }
  end
  local lines = {}

  -- Runtime module inventory (maxa.runtime.M.modules).
  local rok, rt = pcall(require, "maxa.runtime")
  if rok and type(rt) == "table" and rt.M and type(rt.M.modules) == "table" then
    local missing = {}
    for _, name in ipairs(rt.M.modules) do
      local lk = pcall(require, "maxa.runtime." .. name)
      if not lk then
        missing[#missing + 1] = name
      end
    end
    if #missing == 0 then
      lines[#lines + 1] = ("maxa runtime: OK (%d modules)"):format(#rt.M.modules)
    else
      lines[#lines + 1] = "maxa runtime: FAIL missing " .. table.concat(missing, ", ")
    end
  else
    lines[#lines + 1] = "maxa runtime: FAIL (entrypoint unavailable)"
  end

  -- Config validity.
  if type(cfg) == "table" then
    lines[#lines + 1] = "config: OK"
  else
    lines[#lines + 1] = "config: FAIL (invalid)"
  end

  -- Provider availability projection from the effective config.
  if type(cfg) == "table" then
    local providers = cfg.providers
    if type(providers) == "table" then
      local n = 0
      for _ in pairs(providers) do
        n = n + 1
      end
      lines[#lines + 1] = ("providers: %d configured"):format(n)
    else
      lines[#lines + 1] = "providers: unknown (no cfg.providers)"
    end
  end

  return { ok = true, result = { lines = lines, text = table.concat(lines, "\n") } }
end

--- Built-in operation family (id -> contract + capability wiring).
--- Mutation/persistence semantics follow the actions-commands-target spec
--- ownership table (session config at safe boundaries, no history rewrite for
--- stop controls, project-local durable history, read-only status/health).
local BUILTINS = {
  -- Chat control family.
  {
    id = "chat.provider",
    kind = "action",
    title = "Select chat provider",
    input_schema = { type = "object", required = { "name" }, properties = { name = { type = "string" } } },
    contexts = { "session", "view" },
    mutates = { "session" },
    requires_idle_request = true,
    persistence = "session",
    category = "chat",
    order = 10,
    handler = simple_handler(nil, "set_provider", "name"),
  },
  {
    id = "chat.model",
    kind = "action",
    title = "Select chat model",
    input_schema = { type = "object", required = { "model" }, properties = { model = { type = "string" } } },
    contexts = { "session", "view" },
    mutates = { "session" },
    requires_idle_request = true,
    persistence = "session",
    category = "chat",
    order = 20,
    handler = simple_handler(nil, "set_model", "model"),
  },
  {
    id = "chat.stop",
    kind = "action",
    title = "Stop current request",
    input_schema = {},
    contexts = { "session", "view" },
    mutates = { "session" },
    requires_idle_request = false,
    persistence = "none",
    category = "chat",
    order = 30,
    handler = simple_handler("request_control", "stop"),
  },
  {
    id = "chat.soft_stop",
    kind = "action",
    title = "Soft stop after current turn",
    input_schema = {},
    contexts = { "session", "view" },
    mutates = { "session" },
    requires_idle_request = false,
    persistence = "none",
    category = "chat",
    order = 40,
    handler = simple_handler("request_control", "soft_stop"),
  },
  {
    id = "chat.context_stop",
    kind = "action",
    title = "Arm context-limit stop",
    input_schema = { type = "object", required = { "target" }, properties = { target = { type = "any" } } },
    contexts = { "session", "view" },
    mutates = { "session" },
    requires_idle_request = false,
    persistence = "none",
    category = "chat",
    order = 50,
    handler = simple_handler("request_control", "context_stop", "target"),
  },
  {
    id = "chat.clear",
    kind = "action",
    title = "Clear rendered messages",
    input_schema = {},
    contexts = { "session", "view" },
    mutates = { "view" },
    requires_idle_request = false,
    persistence = "none",
    category = "chat",
    order = 60,
    handler = simple_handler(nil, "clear"),
  },
  -- View family.
  {
    id = "view.hide",
    kind = "action",
    title = "Hide chat view",
    input_schema = {},
    contexts = { "view" },
    mutates = { "view" },
    requires_idle_request = false,
    persistence = "none",
    category = "view",
    order = 10,
    handler = simple_handler("view_control", "hide"),
  },
  {
    id = "view.reattach",
    kind = "action",
    title = "Reattach chat view",
    input_schema = {},
    contexts = { "view" },
    mutates = { "view" },
    requires_idle_request = false,
    persistence = "none",
    category = "view",
    order = 20,
    handler = simple_handler("view_control", "reattach"),
  },
  {
    id = "view.close_view",
    kind = "action",
    title = "Close chat view",
    input_schema = {},
    contexts = { "view" },
    mutates = { "view" },
    requires_idle_request = false,
    persistence = "none",
    category = "view",
    order = 30,
    handler = simple_handler("view_control", "close_view"),
  },
  {
    id = "view.close_session",
    kind = "action",
    title = "Close chat session",
    input_schema = {},
    contexts = { "view", "session" },
    mutates = { "session", "view" },
    requires_idle_request = false,
    persistence = "none",
    category = "view",
    order = 40,
    handler = simple_handler(nil, "close_session"),
  },
  -- History family (context.history service interface).
  {
    id = "history.save",
    kind = "command",
    title = "Save current session",
    input_schema = {},
    contexts = { "project", "session" },
    mutates = { "history" },
    requires_idle_request = false,
    persistence = "project",
    category = "history",
    order = 10,
    handler = history_handler("save"),
  },
  {
    id = "history.list",
    kind = "command",
    title = "List saved sessions",
    input_schema = {},
    contexts = { "project" },
    mutates = { "none" },
    requires_idle_request = false,
    persistence = "none",
    category = "history",
    order = 20,
    handler = history_handler("list"),
  },
  {
    id = "history.open",
    kind = "command",
    title = "Open a saved session",
    input_schema = {},
    contexts = { "project", "session" },
    mutates = { "session" },
    requires_idle_request = false,
    persistence = "none",
    category = "history",
    order = 30,
    handler = history_handler("open"),
  },
  {
    id = "history.fork",
    kind = "command",
    title = "Fork current session",
    input_schema = {},
    contexts = { "project", "session" },
    mutates = { "history" },
    requires_idle_request = false,
    persistence = "project",
    category = "history",
    order = 40,
    handler = history_handler("fork"),
  },
  {
    id = "history.scratch",
    kind = "command",
    title = "Create scratch session",
    input_schema = {},
    contexts = { "project", "session" },
    mutates = { "history" },
    requires_idle_request = false,
    persistence = "project",
    category = "history",
    order = 50,
    handler = history_handler("scratch"),
  },
  {
    id = "history.merge",
    kind = "command",
    title = "Merge sessions",
    input_schema = {},
    contexts = { "project", "session" },
    mutates = { "history" },
    requires_idle_request = false,
    persistence = "project",
    category = "history",
    order = 60,
    handler = history_handler("merge"),
  },
  {
    id = "history.transfer",
    kind = "command",
    title = "Transfer session to another project",
    input_schema = {},
    contexts = { "project" },
    mutates = { "history", "filesystem" },
    requires_idle_request = false,
    persistence = "project",
    category = "history",
    order = 70,
    handler = history_handler("transfer"),
  },
  {
    id = "history.rewind",
    kind = "command",
    title = "Rewind session",
    input_schema = {},
    contexts = { "project", "session" },
    mutates = { "history" },
    requires_idle_request = false,
    persistence = "project",
    category = "history",
    order = 80,
    handler = history_handler("rewind"),
  },
  {
    id = "history.redo",
    kind = "command",
    title = "Redo session step",
    input_schema = {},
    contexts = { "project", "session" },
    mutates = { "history" },
    requires_idle_request = false,
    persistence = "project",
    category = "history",
    order = 90,
    handler = history_handler("redo"),
  },
  {
    id = "history.compact",
    kind = "command",
    title = "Compact session history",
    input_schema = {},
    contexts = { "project", "session" },
    mutates = { "history" },
    requires_idle_request = false,
    persistence = "project",
    category = "history",
    order = 100,
    handler = history_handler("compact"),
  },
  {
    id = "history.trace",
    kind = "command",
    title = "Start or query session trace",
    input_schema = {},
    contexts = { "project", "session" },
    mutates = { "history" },
    requires_idle_request = false,
    persistence = "project",
    category = "history",
    order = 110,
    handler = history_handler("trace"),
  },
  -- Status family (read-only projection).
  {
    id = "status.panel",
    kind = "action",
    title = "Show session status panel",
    input_schema = {},
    contexts = { "session", "view" },
    mutates = { "none" },
    requires_idle_request = false,
    persistence = "none",
    category = "status",
    order = 10,
    handler = status_panel_handler,
  },
  -- Health family (read-only diagnostics).
  {
    id = "health.check",
    kind = "command",
    title = "Run runtime health checks",
    input_schema = {},
    contexts = { "global", "project" },
    mutates = { "none" },
    requires_idle_request = false,
    persistence = "none",
    category = "health",
    order = 10,
    handler = health_check_handler,
  },
}

--- Register the full built-in family into a registry. Idempotent: re-running
--- with the same definitions succeeds (same definition hashes).
---@param registry table registry instance (maxa.runtime.actions)
---@return table the registry (chainable)
function M.register_all(registry)
  for _, def in ipairs(BUILTINS) do
    local ok, err = registry:register(def)
    if not ok then
      error(("actions.builtin: register %q failed: %s"):format(def.id, tostring(err and err.message or err)))
    end
  end
  return registry
end

return M
