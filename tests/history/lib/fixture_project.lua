-- filepath: tests/history/lib/fixture_project.lua
--- Phase-4 W1 fixture project factory.
---
--- `make_fixture_project()` creates a temp directory with a `.maxa/` marker so
--- history storage tests run against an isolated project root (the development
--- mother repository's `.supermax/` is absent/inaccessible — contract requirement
--- from runtime-fixture-contract §Acceptance gate). Returns
--- { root=..., history_dir=..., cleanup=fun() }; `with_project(cb)` runs a fixture
--- body with guaranteed cleanup even when the body throws.

local M = {}

local seq = 0

---@return {root: string, history_dir: string, cleanup: fun()}
function M.make_fixture_project()
  seq = seq + 1
  local base = vim.fn.tempname() .. "_hx" .. seq
  local ok, err = vim.fn.mkdir(base, "p")
  assert(ok == 0 or ok == 1, ("make_fixture_project: mkdir failed: %s"):format(tostring(err)))
  vim.fn.mkdir(base .. "/.maxa", "p")
  return {
    root = base,
    history_dir = base .. "/.maxa/history",
    cleanup = function()
      pcall(vim.fn.delete, base, "rf")
    end,
  }
end

--- Run a fixture body inside a fresh fixture project; cleanup always runs.
---@param cb fun(proj: {root: string, history_dir: string, cleanup: fun()}): nil
function M.with_project(cb)
  local proj = M.make_fixture_project()
  local ok, err = pcall(cb, proj)
  proj.cleanup()
  if not ok then
    error(err, 0)
  end
end

return M
