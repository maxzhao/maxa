local completion = require("maxa.providers.completion")

local api = vim.api
local M = {}

---Omnifunc for maxa_ai buffers
---@param findstart number 1 for finding start position, 0 for returning completions
---@param base string The text to complete (only used when findstart == 0)
---@return number|table
function M.omnifunc(findstart, base)
  if findstart == 1 then
    local line = api.nvim_get_current_line()
    local col = api.nvim_win_get_cursor(0)[2]
    local token = completion.token_at_cursor(line, col, api.nvim_get_current_buf())
    return token and token.start_col or -1
  end

  local trigger_char = base:sub(1, 1)
  local items = {}
  if trigger_char == "#" then
    for _, item in ipairs(completion.variables(api.nvim_get_current_buf())) do
      table.insert(items, {
        word = item.label,
        abbr = item.label:sub(2),
        menu = item.detail or item.description,
        kind = "v",
        icase = 1,
      })
    end
  elseif trigger_char == "@" then
    for _, item in ipairs(completion.tools(api.nvim_get_current_buf())) do
      table.insert(items, {
        word = item.label,
        abbr = item.label:sub(2),
        menu = item.detail or item.description,
        kind = "f",
        icase = 1,
      })
    end
  elseif trigger_char == "/" then
    for _, item in ipairs(completion.slash_commands(api.nvim_get_current_buf())) do
      table.insert(items, {
        word = item.label,
        abbr = item.label:sub(2),
        menu = item.detail or item.description,
        kind = "f",
        icase = 1,
        user_data = {
          command = item.label:sub(2),
          type = item.type,
          config = item.config,
          from_prompt_library = item.from_prompt_library,
        },
      })
    end
  end
  return items
end

return M
