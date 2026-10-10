local log = require("maxa.utils.log")

---@class MaxaAI.SlashCommand.Provider.Snacks: MaxaAI.SlashCommand.Provider
local Snacks = {}

---@param args MaxaAI.SlashCommand.ProviderArgs
function Snacks.new(args)
  local ok, snacks = pcall(require, "snacks")
  if not ok then
    return log:error("Snacks is not installed")
  end

  return setmetatable({
    output = args.output,
    provider = snacks,
    title = args.title,
  }, { __index = Snacks })
end

---The function to display the provider
---@return function
function Snacks:display()
  return function(picker)
    picker:close()
    local items = picker:selected({ fallback = true })
    if items then
      vim.iter(items):each(function(item)
        return self.output(item)
      end)
    end

    return true
  end
end

return Snacks
