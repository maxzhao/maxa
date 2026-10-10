local source = {}

function source.new(config)
  return setmetatable({ config = config }, { __index = source })
end

function source:is_available()
  return vim.bo.filetype == "maxa_ai"
end

source.get_position_encoding_kind = function()
  return "utf-8"
end

function source:get_trigger_characters()
  return { "@" }
end

function source:get_keyword_pattern()
  return [[\%(@\|#\|/\)\S*]]
end

function source:complete(params, callback)
  local items = require("maxa.providers.completion").tools(params.context and params.context.bufnr)
  local tool_kind = require("cmp").lsp.CompletionItemKind.Snippet

  vim.iter(items):map(function(item)
    if item.name == "tools" then
      item.kind = tool_kind
    end
    item.config = self.config
    item.context = {
      bufnr = params.context.bufnr,
    }
    item.insertText = item.label
    return item
  end)

  callback({
    items = items,
    isIncomplete = false,
  })
end

return source
