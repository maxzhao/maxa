-- filepath: tests/history/lib/assert.lua
--- Phase-4 W1 history assert helpers. Mirrors tests/state/lib/assert.lua style:
--- each fixture creates a fresh context via assert_mod.new(); failures are recorded
--- (never thrown mid-fixture); the fixture must `error(...)` at the end when
--- ctx.ok is false and print an OK marker on success.

local M = {}

--- Deep equality for plain JSON-safe tables (used for envelope/message compare).
---@param a any
---@param b any
---@return boolean
local function deep_equal(a, b)
  if a == b then
    return true
  end
  if type(a) ~= "table" or type(b) ~= "table" then
    return false
  end
  -- Both are arrays or both are maps (compare by length when both lists).
  local a_list = vim.islist(a)
  local b_list = vim.islist(b)
  if a_list ~= b_list then
    return false
  end
  if a_list then
    if #a ~= #b then
      return false
    end
    for i = 1, #a do
      if not deep_equal(a[i], b[i]) then
        return false
      end
    end
    return true
  end
  for k, v in pairs(a) do
    if b[k] == nil or not deep_equal(v, b[k]) then
      return false
    end
  end
  for k in pairs(b) do
    if a[k] == nil then
      return false
    end
  end
  return true
end

--- Create a fresh assertion context.
---@return table ctx { ok=boolean, failures=table[], check=fun, assert_eq=fun, assert_same_table=fun }
function M.new()
  local ctx = {
    ok = true,
    failures = {},
  }
  --- Record a failed assertion. Never throws; the fixture decides when to abort.
  ---@param cond boolean
  ---@param msg string
  function ctx.check(cond, msg)
    if not cond then
      ctx.ok = false
      ctx.failures[#ctx.failures + 1] = msg
      print("HISTORY_FAIL: " .. msg)
    end
  end
  --- Equality assertion with inspect-diff in the message.
  ---@param got any
  ---@param want any
  ---@param msg string
  function ctx.assert_eq(got, want, msg)
    if got ~= want then
      ctx.check(false, ("%s (got %s, want %s)"):format(msg, vim.inspect(got), vim.inspect(want)))
    end
  end
  --- Deep table equality assertion.
  ---@param got any
  ---@param want any
  ---@param msg string
  function ctx.assert_same_table(got, want, msg)
    if not deep_equal(got, want) then
      ctx.check(false, ("%s (got %s, want %s)"):format(msg, vim.inspect(got), vim.inspect(want)))
    end
  end
  return ctx
end

return M
