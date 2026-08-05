-- filepath: lua/maxa/runtime/init.lua
--- maxa runtime entrypoint (phase-0 skeleton).
---
--- Loading this module must never pull in the legacy CodeCompanion/MCPHub runtime
--- or the old hook suite (see guard/init.lua). All runtime sub-modules are loaded
--- through the guarded require.
---
--- Sub-modules that are phase-0 placeholders return an empty `M` table with a
--- `name` field; they are extended by later waves / subagents.
local guard = require("maxa.runtime.guard")

local M = {}

--- Minimum phase-0 module inventory present under lua/maxa/runtime/.
M.modules = {
  "config",
  "protocol",
  "conversation",
  "session",
  "orchestrator",
  "tools",
  "mcp",
  "skills",
  "events",
  "schema",
  "compat",
}

function M._load_phase0_modules()
  local loaded = {}
  for _, mod in ipairs(M.modules) do
    loaded[mod] = guard.require("maxa.runtime." .. mod)
  end
  return loaded
end

function M.load()
  local loaded = M._load_phase0_modules()
  guard.assert_no_forbidden()
  return loaded
end

--- Real-path runtime assembly (phase-3 W1): tool registry + MCP servers +
--- skill discovery/loading through the effective config, plus an idempotent
--- teardown. See maxa/runtime/assemble.lua for the contract. The module is
--- required lazily so loading the runtime entrypoint stays light.
---@param cfg table effective configuration (mcp/skills sections)
---@param opts? table assemble options (events/project_root/cwd/root overrides)
---@return table assembly { tool_registry, mcp_registry, mcp_config, mcp_error,
---   skills_state, errors, teardown }
function M.assemble(cfg, opts)
  return require("maxa.runtime.assemble").assemble(cfg, opts)
end

-- Load skeleton eagerly when required as the runtime entrypoint.
M._modules_loaded = M.load()

return M
