-- Internal mutable state shared by Maxa AI runtime modules.
local M = {
  buffers = {},
  chat_metadata = {},
  current_context = nil,
  last_terminal = nil,
}

return M
