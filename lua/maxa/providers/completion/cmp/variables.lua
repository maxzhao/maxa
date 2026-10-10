local source = {}

function source.new()
  return setmetatable({}, { __index = source })
end

function source:is_available()
  return vim.bo.filetype == "maxa_ai"
end

source.get_position_encoding_kind = function()
  return "utf-8"
end

function source:get_trigger_characters()
  return { "#" }
end

function source:get_keyword_pattern()
  return [[\%(@\|#\|/\)\S*]]
end

function source:complete(params, callback)
  local items = require("maxa.providers.completion").variables(params.context and params.context.bufnr)
  local kind = require("cmp").lsp.CompletionItemKind.Variable

  vim.iter(items):map(function(item)
    item.kind = kind
    item.insertText = item.label
    return item
  end)

  callback({
    items = items,
    isIncomplete = false,
  })
end

return source
