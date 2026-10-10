local M = {}
local setup_complete = false

---@return boolean
function M.setup()
  if setup_complete then
    return true
  end
  local blink = require("blink.cmp")
  pcall(function()
    local add_provider = blink.add_source_provider or blink.add_provider --[[@type function]]
    add_provider("maxa_ai", {
      name = "Maxa AI",
      module = "maxa.providers.completion.blink",
      enabled = true,
      score_offset = 10,
    })
  end)
  pcall(function()
    blink.add_filetype_source("maxa_ai", "maxa_ai")
  end)
  setup_complete = true
  return true
end

function M.reset_setup()
  setup_complete = false
end

return M
