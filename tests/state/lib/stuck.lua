-- filepath: tests/state/lib/stuck.lua
--- Shared scripted provider helper for W7 watchdog fixtures. Test-only; never
--- required from the runtime.
---
--- A script maps call ordinals to behaviors (the last entry repeats for calls
--- beyond the script length — stable tail):
---   "stuck"                     -> provider.stream returns a live handle that
---                                  NEVER fires a terminal callback (a hang;
---                                  the watchdog owns the terminal instead)
---   "tool"                      -> mock chunks producing one tool call
---                                  (call_id "c1", name "slow") + completion
---   <string>                    -> mock text chunks (single delta) -> done
---   <function>(params, callbacks) -> custom behavior (returns the handle)
---
--- The provider exposes the same unified stream surface as the mock adapter;
--- `scripted.stream` ignores params for behavior selection (call count wins)
--- so automatic/retry submits (provider_params = {}) drive it deterministically.

local protocol = require("maxa.runtime.protocol")
local normalize = require("maxa.runtime.protocol.normalize")

local mock = protocol.get(protocol.providers.mock)

local M = {}

---@param script table[] per-call behavior list (see module doc)
---@return table provider scripted provider
---@return fun(): integer calls accessor returning the current call count
function M.make(script)
  local provider = { name = "stuck-scripted", protocol = "mock", capabilities = mock.capabilities }
  local calls = 0
  function provider.stream(_, params, callbacks)
    calls = calls + 1
    local behavior = script[math.min(calls, #script)]
    if behavior == "stuck" then
      return {
        active = true,
        cancel = function()
          return false
        end,
      }
    end
    if type(behavior) == "function" then
      return behavior(params, callbacks)
    end
    if behavior == "tool" then
      params = vim.tbl_deep_extend("force", params or {}, {
        chunks = {
          normalize.tool_call_started("c1", "slow"),
          normalize.tool_call_completed("c1", "{}"),
        },
      })
      return mock.stream(mock, params, callbacks)
    end
    params = vim.tbl_deep_extend("force", params or {}, { chunks = { behavior } })
    return mock.stream(mock, params, callbacks)
  end
  return provider, function()
    return calls
  end
end

return M
