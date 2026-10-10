local completion = require("maxa.providers.completion")

local source = {}

function source.new(config)
  return setmetatable({ config = config }, { __index = source })
end

function source:is_available()
  return vim.bo.filetype == "maxa_ai"
end

function source:get_trigger_characters()
  return { "/" }
end

function source:get_keyword_pattern()
  return [[/[-[:alnum:]_:]\+]]
end

function source:complete(params, callback)
  local items = completion.slash_commands(params.context.bufnr)
  local kind = require("cmp").lsp.CompletionItemKind.Function

  vim.iter(items):map(function(item)
    item.kind = kind
    item.context = {
      bufnr = params.context.bufnr,
      cursor = params.context.cursor,
    }
  end)

  callback({
    items = items,
    isIncomplete = false,
  })
end

---Execute selected item
---@param item table The selected item from the completion menu
---@param callback function
---@return nil
function source:execute(item, callback)
  local bufnr = item.context.bufnr
  local chat = require("maxa").buf_get_chat(bufnr)
  local cursor = vim.api.nvim_win_get_cursor(0)
  local word = item.word or item.label or ""
  local ok, err = completion.prepare_slash_command(item, chat, bufnr, {
    start = { row = cursor[1] - 1, col = cursor[2] - #word },
    ["end"] = { row = cursor[1] - 1, col = cursor[2] },
    revalidate_selection = true,
  })
  if ok then
    completion.slash_commands_execute(item, chat)
  else
    vim.notify("[Maxa AI] Could not prepare slash command: " .. tostring(err), vim.log.levels.ERROR)
  end

  callback(item)
  vim.bo[bufnr].buflisted = false
end

return source
