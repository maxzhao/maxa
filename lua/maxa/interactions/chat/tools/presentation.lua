-- Pure local ToolView contract. No execution, authorization, or buffer access.
local M = {}
local helpers = require("maxa.interactions.chat.tools.display_helpers")

function M.normalize(view)
  if type(view) ~= "table" then return nil end
  if view.summary ~= nil and view.summary ~= false and type(view.summary) ~= "string" then return nil end
  if view.progress ~= nil and type(view.progress) ~= "boolean" then return nil end
  if view.right ~= nil and type(view.right) ~= "string" then return nil end
  local out = { summary = view.summary, progress = view.progress,
    right = view.right and view.right:gsub("[\r\n]", " "), blocks = {} }
  if view.blocks ~= nil and (type(view.blocks) ~= "table" or not vim.islist(view.blocks)) then return nil end
  for _, block in ipairs(view.blocks or {}) do
    if type(block) ~= "table" or type(block.content) ~= "string" then return nil end
    local b = { kind = block.kind, content = block.content }
    if b.kind == "message" then
      if block.role ~= "assistant" and block.role ~= "user" then return nil end
      b.role = block.role
    elseif b.kind == "fold" then
      if type(block.title) ~= "string" or (block.collapsed ~= nil and type(block.collapsed) ~= "boolean") then return nil end
      b.title, b.collapsed = block.title, block.collapsed ~= false
    elseif b.kind ~= "markdown" then return nil end
    out.blocks[#out.blocks + 1] = b
  end
  return out
end

function M.view(definition, args, result, name)
  if definition and type(definition.display) == "function" then
    local ok, view = pcall(definition.display, vim.deepcopy(helpers.normalize_args(args)), result and vim.deepcopy(result))
    if ok then
      local normalized = M.normalize(view)
      if normalized then return normalized end
    end
  end
  return { summary = name or (definition and definition.name) or "unknown", blocks = {} }
end

-- Current builtins only; Native definitions are bound by authorized execution.
function M.builtin(name, args, result)
  local ok, definition = pcall(function()
    return require("maxa.interactions.chat.tools.builtin").resolve(name)
  end)
  return M.view(ok and definition or nil, args, result, name)
end

return M
