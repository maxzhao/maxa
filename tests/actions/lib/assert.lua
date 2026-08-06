-- filepath: tests/actions/lib/assert.lua
--- Phase-5 W4 actions-suite assert helpers (same pattern as tests/state/lib/
--- assert.lua, with an ACTIONS_ failure prefix).
---
--- Convention (runner contract): fixtures call check/assert_eq on their own
--- context; when any check fails the fixture must `error(...)` at the end (the
--- runner records the failure and continues) and print an OK marker on success.

local M = {}

--- Create a fresh assertion context.
---@return table ctx { ok=boolean, failures=table[], check=fun, assert_eq=fun }
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
      print("ACTIONS_FAIL: " .. msg)
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
  return ctx
end

return M
