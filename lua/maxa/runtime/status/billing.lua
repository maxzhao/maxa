-- filepath: lua/maxa/runtime/status/billing.lua
--- Optional quota/billing projection (phase-5 W2). Contract
--- (runtime-fixture-contract §Events, spine, spinner and lualine):
--- provider quota/billing failures yield absent/stale TYPED projections, never
--- a raise and never a Chat runtime failure.
---
--- Result contract:
---   { available = true,  enabled = true, data = <provider data> }  success
---   { available = false, enabled = true, stale = true, error = <msg> } failure
---   { available = false, enabled = false }                          disabled
---
--- Provider reference resolution (by-name, recorded decision):
---   * nil              -> disabled result (empty implementation)
---   * function         -> called with (usage); any error -> stale typed result
---   * string (module)  -> pcall(require); the module must be callable or expose
---     `.snapshot(usage)` (both contracts receive (usage) and return quota
---     data); anything else -> stale typed result
---
--- The module never raises: every failure path returns a typed table.

local M = {}

M.name = "status.billing"

--- Resolve a provider reference to a callable (nil when unresolvable).
--- Never raises: require failures and shape mismatches yield nil.
---@param ref function|string|nil
---@return function|nil callable (receives usage)
---@return string|nil error message
local function resolve_provider(ref)
  if type(ref) == "function" then
    return ref, nil
  end
  if type(ref) == "string" then
    local ok, mod = pcall(require, ref)
    if not ok or mod == nil then
      return nil, ("billing provider require failed: %s"):format(tostring(mod or "nil"))
    end
    if type(mod) == "function" then
      return mod, nil
    end
    if type(mod) == "table" and type(mod.snapshot) == "function" then
      -- Unify the module contract with the function contract: both receive
      -- (usage) and return quota data.
      local snap = mod.snapshot
      return function(usage)
        return snap(usage)
      end, nil
    end
    return nil, ("billing provider %q has no callable snapshot"):format(ref)
  end
  return nil, ("billing provider must be a function or module name, got %s"):format(type(ref))
end

--- Build the typed quota projection for a provider reference and usage.
--- Any provider failure becomes { available=false, stale=true, error=... }.
---@param provider_ref function|string|nil provider reference (by-name)
---@param usage table|nil normalized usage (schema.usage shape)
---@return table typed projection (see module contract)
function M.snapshot(provider_ref, usage)
  if provider_ref == nil then
    return { available = false, enabled = false }
  end
  local callable, err = resolve_provider(provider_ref)
  if not callable then
    return { available = false, enabled = true, stale = true, error = err }
  end
  local ok, data = pcall(callable, usage)
  if not ok then
    return {
      available = false,
      enabled = true,
      stale = true,
      error = tostring(data),
    }
  end
  if data == nil then
    return { available = false, enabled = true, stale = true, error = "billing provider returned nil" }
  end
  return { available = true, enabled = true, data = data }
end

return M
