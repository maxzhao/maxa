--[[
Methods for handling interactions between the chat buffer and tools
--]]

---@class MaxaAI.Chat.ToolRegistry
---@field chat MaxaAI.Chat
---@field flags table Flags that external functions can update
---@field in_use table<string, boolean> Tools that are in use on the chat buffer
---@field schemas table<string, table> The config for the tools in use

---@class MaxaAI.Chat.ToolRegistry
local ToolRegistry = {}

local utils = require("maxa.utils")

---@class MaxaAI.Chat.ToolsArgs
---@field chat MaxaAI.Chat

---@param args MaxaAI.Chat.ToolsArgs
function ToolRegistry.new(args)
  local self = setmetatable({
    chat = args.chat,
    flags = {},
    in_use = {},
    schemas = {},
  }, { __index = ToolRegistry })

  return self
end

---Add context about the tool in the chat buffer
---@param chat MaxaAI.Chat The chat buffer
---@param id string The id of the tool
---@param opts? table Optional parameters for the context_item
---@return nil
local function add_context(chat, id, opts)
  chat.context:add({
    source = "tool",
    name = "tool",
    id = id,
    opts = opts,
  })
end

---Add the tool's schema to the chat buffer
---@param self MaxaAI.Chat.ToolRegistry The registry object
---@param tool table The resolved tool
---@param id string The id of the tool
---@return nil
local function add_schema(self, tool, id)
  self.schemas[id] = tool.schema
end

---Add the given tool to the chat buffer
---@param tool string The name of the tool
---@param tool_config table The tool from the config
---@param opts? table Optional parameters
---@return nil
function ToolRegistry:add(tool, tool_config, opts)
  opts = opts or { visible = true }

  local id = "<tool>" .. tool .. "</tool>"

  local is_adapter_tool = tool_config and tool_config._adapter_tool == true
  if is_adapter_tool then
    add_context(self.chat, id, opts)
    add_schema(self, {
      schema = {
        name = tool,
        description = tool_config.description or "",
        _meta = {
          adapter_tool = true,
        },
      },
    }, id)
  else
    local resolved_tool = self.chat.tools.resolve(tool_config)
    if not resolved_tool or self.in_use[tool] then
      return
    end

    add_context(self.chat, id, opts)
    add_schema(self, resolved_tool, id)
  end

  utils.fire("ChatToolAdded", { bufnr = self.chat.bufnr, id = self.chat.id, tool = tool })
  self.in_use[tool] = true

  return self
end

---Determine if the chat buffer has any tools in use
---@return boolean
function ToolRegistry:loaded()
  return not vim.tbl_isempty(self.in_use)
end

---Clear the tools
---@return nil
function ToolRegistry:clear()
  self.flags = {}
  self.in_use = {}
  self.schemas = {}
end

return ToolRegistry
