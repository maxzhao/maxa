-- filepath: lua/maxa/runtime/mcp/init.lua
--- maxa MCP subsystem (phase-0 placeholder extended by phase-3 W3).
---
--- The MCP subsystem lives in the sibling modules:
---   * mcp/config.lua  — `.maxa/mcp/servers.yaml` load/validate/substitute/diff
---   * mcp/client.lua  — stdio JSON-RPC client (Content-Length framing)
---   * mcp/server.lua  — external process lifecycle state machine
---   * mcp/registry.lua — server registry (immutable id/kind/snapshot/state)
---   * mcp/native.lua  — native primitive registration/lifecycle (phase-3 W4)
---
--- The subsystem entry (`maxa.runtime.mcp`) stays a lightweight facade: it
--- must not eagerly require the heavy modules (they pull plenary.job etc. only
--- on demand). Loading this module never loads codecompanion.* / mcphub.* /
--- lua/util/hooks/*.
local M = { name = "mcp" }

--- Sub-module names (runtime inventory / diagnostics).
M.modules = { "config", "client", "server", "registry", "native" }

---@param name string one of M.modules
---@return any module
function M.require(name)
  assert(vim.tbl_contains(M.modules, name), ("mcp.init.require: unknown sub-module %q"):format(tostring(name)))
  return require("maxa.runtime.mcp." .. name)
end

return M
