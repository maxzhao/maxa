-- filepath: tests/prompts/lib/fixture_project.lua
--- Phase-5 W5 fixture project factory (pattern: tests/history/lib/
--- fixture_project.lua). Creates a temp project root; the development mother
--- repository's `.supermax/` is absent/inaccessible (contract requirement).
--- Returns { root=..., cleanup=fun() }; `with_project(cb)` runs a fixture body
--- with guaranteed cleanup even when the body throws.

local M = {}

local seq = 0

---@param rel string
---@param content string
---@return string path
local function write_text(root, rel, content)
  local path = root .. "/" .. rel
  local dir = path:match("^(.*)/[^/]+$")
  vim.fn.mkdir(dir, "p")
  vim.fn.writefile(vim.split(content, "\n", { plain = true }), path)
  return path
end

---@return {root: string, cleanup: fun()}
function M.make_fixture_project()
  seq = seq + 1
  local base = vim.fn.tempname() .. "_pr" .. seq
  local ok, err = vim.fn.mkdir(base, "p")
  assert(ok == 0 or ok == 1, ("fixture_project: mkdir failed: %s"):format(tostring(err)))
  return {
    root = base,
    cleanup = function()
      pcall(vim.fn.delete, base, "rf")
    end,
  }
end

--- Write a file (with parent dirs) inside a fixture project.
---@param proj {root: string}
---@param rel string
---@param content string
---@return string path
function M.write(proj, rel, content)
  return write_text(proj.root, rel, content)
end

--- Run a fixture body inside a fresh fixture project; cleanup always runs.
---@param cb fun(proj: {root: string, cleanup: fun()}): nil
function M.with_project(cb)
  local proj = M.make_fixture_project()
  local ok, err = pcall(cb, proj)
  proj.cleanup()
  if not ok then
    error(err, 0)
  end
end

return M
