-- filepath: tests/actions/discover.lua
--- Phase-5 W4 discovery fixtures: deterministic category/order/id ordering,
--- condition-predicate filtering without handler invocation, and read-only
--- public items (no handler/condition exposure).

local assert_mod = require("tests.actions.lib.assert")
local actions = require("maxa.runtime.actions")

local a = assert_mod.new()
local reg = actions.new()

local handler_calls = 0
local condition_calls = 0

local d_beta = {
  id = "discover.beta",
  kind = "action",
  title = "Beta",
  input_schema = {},
  contexts = { "view" },
  mutates = { "none" },
  requires_idle_request = false,
  persistence = "none",
  category = "cat.b",
  order = 1,
  condition = function(ctx)
    condition_calls = condition_calls + 1
    return ctx.visible
  end,
  handler = function()
    handler_calls = handler_calls + 1
    return "beta"
  end,
}
local d_alpha = {
  id = "discover.alpha",
  kind = "command",
  title = "Alpha",
  input_schema = {},
  contexts = { "global" },
  mutates = { "none" },
  requires_idle_request = false,
  persistence = "none",
  category = "cat.a",
  order = 2,
  handler = function()
    handler_calls = handler_calls + 1
    return "alpha"
  end,
}
local d_gamma = {
  id = "discover.gamma",
  kind = "action",
  title = "Gamma",
  input_schema = {},
  contexts = { "project" },
  mutates = { "none" },
  requires_idle_request = false,
  persistence = "none",
  category = "cat.a",
  order = 1,
  condition = function(ctx)
    condition_calls = condition_calls + 1
    return ctx.visible
  end,
  handler = function()
    handler_calls = handler_calls + 1
    return "gamma"
  end,
}

reg:register(d_beta)
reg:register(d_alpha)
reg:register(d_gamma)

-- discover with ctx.visible=true: all three items, sorted cat.a/order1,
-- cat.a/order2, cat.b.
local items = reg:discover({ visible = true })
a.check(#items == 3, "discover: all visible items (" .. #items .. ")")
a.check(items[1].id == "discover.gamma", "discover: cat.a/order1 first (got " .. items[1].id .. ")")
a.check(items[2].id == "discover.alpha", "discover: cat.a/order2 second (got " .. items[2].id .. ")")
a.check(items[3].id == "discover.beta", "discover: cat.b third (got " .. items[3].id .. ")")
a.check(handler_calls == 0, "discover: handlers never invoked (" .. handler_calls .. ")")

-- discover with ctx.visible=false: only the unconditioned item survives.
local items2 = reg:discover({ visible = false })
a.check(#items2 == 1 and items2[1].id == "discover.alpha", "discover: condition filters hidden items")

-- discover returns read-only public items.
a.check(items2[1].handler == nil and items2[1].condition == nil, "discover: items expose no handler/condition")

-- condition predicates were evaluated (2 per discover pass), handlers never ran.
a.check(condition_calls == 4, "discover: condition called for conditioned items (2+2, got " .. condition_calls .. ")")

if not a.ok then
  error("DISCOVER_FIXTURE_FAILED: " .. table.concat(a.failures, "; "))
end
print("DISCOVER_FIXTURE_OK")
