-- filepath: tests/actions/register.lua
--- Phase-5 W4 registry registration fixtures: success, duplicate same-hash
--- idempotency, duplicate different-hash rejection, missing-field rejection,
--- invalid values, deterministic list ordering and the default singleton.

local assert_mod = require("tests.actions.lib.assert")
local actions = require("maxa.runtime.actions")

local a = assert_mod.new()

local function base_def(id)
  return {
    id = id,
    kind = "action",
    title = "Test " .. id,
    input_schema = {},
    contexts = { "session", "view" },
    mutates = { "view" },
    requires_idle_request = false,
    persistence = "none",
    handler = function()
      return "ok"
    end,
  }
end

-- 1. registration success + public item projection.
local reg = actions.new()
local ok, err = reg:register(base_def("test.one"))
a.check(ok == true, "register: success returns true (" .. tostring(err and err.message or err) .. ")")
local item = reg:get("test.one")
a.check(item ~= nil, "register: get returns the item")
a.check(item.id == "test.one" and item.kind == "action" and item.title == "Test test.one", "register: public item fields")
a.check(item.handler == nil and item.condition == nil, "register: public item hides handler/condition")
a.check(reg:get("test.missing-id") == nil, "register: get returns nil for unknown id")

-- 2. duplicate same hash is idempotent.
local ok2, err2 = reg:register(base_def("test.one"))
a.check(ok2 == true, "register: duplicate same hash is idempotent (" .. tostring(err2 and err2.message or err2) .. ")")

-- 3. duplicate different hash is rejected with a typed error.
local changed = base_def("test.one")
changed.title = "Changed title"
local ok3, err3 = reg:register(changed)
a.check(ok3 == nil, "register: duplicate different hash rejected")
a.check(err3 ~= nil and err3.code == "duplicate_hash", "register: duplicate error code duplicate_hash (got " .. tostring(err3 and err3.code) .. ")")

-- 4. missing required fields are rejected.
local missing_handler = base_def("test.missing")
missing_handler.handler = nil
local ok4, err4 = reg:register(missing_handler)
a.check(ok4 == nil, "register: missing handler rejected")
a.check(err4 ~= nil and err4.code == "missing_field", "register: missing field code missing_field")

local missing_persistence = base_def("test.missing2")
missing_persistence.persistence = nil
local ok5, err5 = reg:register(missing_persistence)
a.check(ok5 == nil and err5 ~= nil and err5.code == "missing_field", "register: missing persistence rejected")

-- 5. invalid values are rejected.
local bad_kind = base_def("test.bad")
bad_kind.kind = "workflow"
local ok6, err6 = reg:register(bad_kind)
a.check(ok6 == nil and err6 ~= nil and err6.code == "invalid_def", "register: invalid kind rejected")

local bad_mutates = base_def("test.bad2")
bad_mutates.mutates = { "everything" }
local ok7, err7 = reg:register(bad_mutates)
a.check(ok7 == nil and err7 ~= nil and err7.code == "invalid_def", "register: unknown mutates value rejected")

-- 6. list() returns all registered items in category/order/id order.
local d_zeta = base_def("test.zeta")
d_zeta.category = "zeta"
d_zeta.order = 5
local d_alpha = base_def("test.alpha")
d_alpha.category = "alpha"
d_alpha.order = 1
local d_beta = base_def("test.beta")
d_beta.category = "alpha"
d_beta.order = 10
reg:register(d_zeta)
reg:register(d_alpha)
reg:register(d_beta)
local listed = reg:list()
a.check(#listed == 4, "register: list includes all registered (" .. #listed .. ")")
a.check(listed[1].id == "test.one", "register: list category '' first (got " .. listed[1].id .. ")")
a.check(listed[2].id == "test.alpha", "register: list category alpha/order1 second (got " .. listed[2].id .. ")")
a.check(listed[3].id == "test.beta", "register: list category alpha/order10 third (got " .. listed[3].id .. ")")
a.check(listed[4].id == "test.zeta", "register: list category zeta last (got " .. listed[4].id .. ")")

-- 7. module-level default singleton exists.
a.check(type(actions.default) == "table" and type(actions.default.register) == "function", "register: module default singleton exists")

if not a.ok then
  error("REGISTER_FIXTURE_FAILED: " .. table.concat(a.failures, "; "))
end
print("REGISTER_FIXTURE_OK")
