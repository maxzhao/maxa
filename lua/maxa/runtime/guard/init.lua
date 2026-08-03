-- filepath: lua/maxa/runtime/guard/init.lua
--- Import guard for the maxa runtime.
---
--- Phase-0 hard rule: no runtime module or test may load the legacy CodeCompanion
--- / MCPHub runtime or the old hook suite. The upstream code (`~/.../codecompanion.nvim`)
--- is only ever read as read-only alignment reference and must never be required
--- from `lua/maxa/runtime/*`.
---
--- Matched module-name prefixes (require-style dotted names):
---   codecompanion.*      -> old plugin runtime
---   mcphub.*             -> MCPHub
---   util.hooks.*         -> legacy hook suite (files under lua/util/hooks/)
local M = {}

M.FORBIDDEN_PREFIXES = {
  "codecompanion",
  "mcphub",
  "util.hooks",
}

---@param module_name string dotted module name as passed to require()
---@return boolean true when the module name is forbidden for the maxa runtime.
function M.is_forbidden(module_name)
  if type(module_name) ~= "string" or module_name == "" then
    return false
  end
  for _, prefix in ipairs(M.FORBIDDEN_PREFIXES) do
    if module_name == prefix or module_name:sub(1, #prefix + 1) == prefix .. "." then
      return true
    end
  end
  return false
end

--- Assert that `package.loaded` currently contains no forbidden module.
--- Intended as a close-out check for a module, test, or headless smoke run.
---@return true on success; error otherwise.
function M.assert_no_forbidden()
  local violations = {}
  for name in pairs(package.loaded) do
    if type(name) == "string" and M.is_forbidden(name) then
      violations[#violations + 1] = name
    end
  end
  if #violations > 0 then
    error(
      "import-guard violation: maxa runtime must not load legacy modules; loaded: " .. table.concat(violations, ", ")
    )
  end
  return true
end

--- Require a module, rejecting forbidden names at the call site.
---@param module_name string dotted module name
---@return any
local original_require = require
function M.require(module_name)
  if M.is_forbidden(module_name) then
    error(("import-guard: refusing to require forbidden module %q"):format(module_name))
  end
  return original_require(module_name)
end

return M
