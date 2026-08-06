-- filepath: tests/status/lualine_s002.lua
--- S-002 lualine component projection (phase-5 W2):
---   * no spine and no active view -> ""
---   * with a registered spine service the text changes (provider/model/usage
---     projected from the spine snapshot)
---   * the component never WRITES the spine: snapshot reference + revision stay
---     identical across component evaluations
---   * clearing the spine restores the empty projection

local assert_mod = require("tests.status.lib.assert")
local status = require("maxa.runtime.host.nvim.status")
local events = require("maxa.runtime.events")
local status_svc = require("maxa.runtime.status")

local ctx = assert_mod.new()
local check = ctx.check
local assert_eq = ctx.assert_eq

-- Baseline: no spine, no active view -> empty.
status.set_spine(nil)
status.set_active_view(nil)
assert_eq(status.lualine_component()(), "", "S002 empty without spine/view")

-- With spine: text changes as the snapshot gains provider/model/usage.
do
  local bus = events.new()
  local svc = status_svc.new({ events = bus, config = {} })
  svc:start()
  status.set_spine(svc)
  local comp = status.lualine_component()
  assert_eq(comp(), "", "S002 idle spine with no data -> empty")

  bus.emit(bus.events.request_started or "request.started", { session_id = "s1", provider = "mock", model = "deepseek-v3" })
  local text = comp()
  check(type(text) == "string" and text ~= "", "S002 spine text non-empty (got " .. tostring(text) .. ")")
  check(text:find("mock", 1, true) ~= nil, "S002 spine text contains provider (got " .. tostring(text) .. ")")
  check(text:find("deepseek-v3", 1, true) ~= nil, "S002 spine text contains model (got " .. tostring(text) .. ")")

  bus.emit(bus.events.usage_updated or "usage.updated", { session_id = "s1", usage = { input_tokens = 7, output_tokens = 3 } })
  text = comp()
  check(text:find("in=7", 1, true) ~= nil, "S002 spine text contains input usage (got " .. tostring(text) .. ")")
  check(text:find("out=3", 1, true) ~= nil, "S002 spine text contains output usage (got " .. tostring(text) .. ")")

  -- Terminal state is projected too.
  bus.emit(bus.events.response_failed or "response.failed", { session_id = "s1", error = { message = "boom" } })
  text = comp()
  check(text:find("failed", 1, true) ~= nil, "S002 spine text contains terminal state (got " .. tostring(text) .. ")")

  -- The component is read-only: snapshot reference and revision unchanged.
  local before = svc:snapshot()
  comp()
  comp()
  local after = svc:snapshot()
  check(after == before, "S002 component does not replace the spine snapshot")
  assert_eq(after.revision, before.revision, "S002 component does not bump the revision")

  -- Clearing the spine restores the empty projection.
  status.set_spine(nil)
  assert_eq(comp(), "", "S002 empty after clearing spine")
  svc:dispose()
end

-- Fallback path stays intact: view projection without spine (regression guard
-- for tests/ui/status.lua semantics: non-empty view text is projected).
do
  status.set_spine(nil)
  local fake_view = {
    projection = function()
      return { status = "idle", usage = nil, text = "idle" }
    end,
  }
  status.set_active_view(fake_view)
  assert_eq(status.lualine_component()(), "idle", "S002 fallback view projection")
  status.set_active_view(nil)
  assert_eq(status.lualine_component()(), "", "S002 empty after clearing view")
end

-- Cleanup global state for other fixtures.
status.set_spine(nil)
status.set_active_view(nil)
