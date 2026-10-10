local M = {}

local function http()
  return require("maxa.adapters.http")
end

---Factory method to resolve an HTTP adapter
---@param adapter string|table
---@param opts? table
---@return MaxaAI.HTTPAdapter
function M.resolve(adapter, opts)
  return http().resolve(adapter, opts)
end

---Factory method to check if an HTTP adapter has been resolved
---@param adapter string|table
---@return boolean
function M.resolved(adapter)
  return http().resolved(adapter)
end

---Factory method to extend an HTTP adapter
---@param adapter string|table
---@param opts? table
---@return MaxaAI.HTTPAdapter
function M.extend(adapter, opts)
  return http().extend(adapter, opts)
end

---Factory method to make an HTTP adapter safe for serialization
---@param adapter string|table
---@return table
function M.make_safe(adapter)
  return http().make_safe(adapter)
end

---@param args { adapter: MaxaAI.HTTPAdapter, model?: string }
---@return MaxaAI.HTTPAdapter
function M.set_model(args)
  return http().set_model(args)
end

---Get a handler function from an HTTP adapter
---@param adapter MaxaAI.HTTPAdapter
---@param handler_name string
---@return function|nil
function M.get_handler(adapter, handler_name)
  return http().get_handler(adapter, handler_name)
end

---Call a handler on an HTTP adapter
---@param adapter MaxaAI.HTTPAdapter
---@param handler_name string
---@param ... any Additional arguments to pass to the handler
---@return any|nil
function M.call_handler(adapter, handler_name, ...)
  local handler = M.get_handler(adapter, handler_name)
  if handler then
    return handler(adapter, ...)
  end
  return nil
end

return M
