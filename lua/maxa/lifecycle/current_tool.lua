-- Runtime owner for the tool currently executing in Maxa AI.
local M = {}

local current

---@param tool table|string|nil
function M.set(tool)
  current = tool
end

---@return table|string|nil
function M.get()
  return current
end

---@param tool? table|string
function M.clear(tool)
  if tool == nil or current == tool then
    current = nil
  end
end

function M.reset_setup()
  current = nil
end

return M
