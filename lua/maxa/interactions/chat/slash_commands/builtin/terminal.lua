local runtime_state = require("maxa.state")
local config = require("maxa.config")
local log = require("maxa.utils.log")
local utils = require("maxa.utils")

local CONSTANTS = {
  NAME = "Terminal Output",
}

---@class MaxaAI.SlashCommand.Terminal: MaxaAI.SlashCommand
local SlashCommand = {}

---@param args MaxaAI.SlashCommand
function SlashCommand.new(args)
  local self = setmetatable({
    Chat = args.Chat,
    config = args.config,
    context = args.context,
  }, { __index = SlashCommand })

  return self
end

local _terminal_data = {}
---Execute the slash command
---@return nil
function SlashCommand:execute()
  local bufnr = runtime_state.last_terminal
  if not bufnr then
    return utils.notify("No recent terminal buffer found", vim.log.levels.WARN)
  end

  local start_line = 0
  if _terminal_data[bufnr] then
    start_line = _terminal_data[bufnr].lines - 3 -- Account for new prompt lines
  end

  local ok, content = pcall(function()
    return vim.api.nvim_buf_get_lines(bufnr, start_line, -1, false)
  end)
  if not ok then
    return log:error("Failed to get terminal output")
  end

  _terminal_data[bufnr] = {
    lines = #content + (_terminal_data[bufnr] and _terminal_data[bufnr].lines or 0),
    timestamp = os.time(),
  }

  local Chat = self.Chat
  Chat:add_message({
    role = config.constants.USER_ROLE,
    content = string.format(
      [[Here is the latest output from terminal `%s`:

```
%s
```]],
      bufnr,
      table.concat(content, "\n")
    ),
  }, { visible = false })
  utils.notify("Terminal output added to chat")
end

return SlashCommand
