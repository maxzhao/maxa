-- Explicit named media presets precede existing per-medium selections.
local M = {}
function M.resolve(req, medium, params)
  local selected = params.preset
  local merged = vim.deepcopy(params)
  if selected ~= nil then
    local value, err = require("maxa.presets").get_preset(selected, medium)
    if not value then return nil, nil, err end
    if params.adapter and params.adapter ~= value.adapter then return nil, nil, "preset and adapter select different services" end
    local adapter = value.adapter
    value.source, value.adapter = nil, nil
    merged = require("maxa.mcphub.native_servers.genai.adapter").merge(value, params)
    merged.preset = nil
    return adapter, merged
  end
  local adapter, err = require("maxa.mcphub.native_servers.genai.session_adapter").resolve(req, medium, params.adapter)
  merged.preset = nil
  return adapter, merged, err
end
return M
