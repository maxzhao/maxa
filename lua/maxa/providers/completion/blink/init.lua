--- @module 'blink.cmp'

local completion = require("maxa.providers.completion")

--- @class blink.cmp.Source
local M = {}

function M.new()
  return setmetatable({}, { __index = M })
end

function M:get_trigger_characters()
  return { "/", "#", "@" }
end

function M:enabled()
  return vim.bo.filetype == "maxa_ai"
end

function M:get_completions(ctx, callback)
  local token = completion.token_at_cursor(ctx.line, ctx.cursor[2], ctx.bufnr)
  local trigger_char = (token and token.trigger) or ctx.trigger.character

  --- @type lsp.Range
  local edit_range = {
    start = {
      line = ctx.bounds.line_number - 1,
      character = token and token.start_col or (ctx.bounds.start_col - 2),
    },
    ["end"] = {
      line = ctx.bounds.line_number - 1,
      character = ctx.cursor[2],
    },
  }
  -- Replace the closing bracket already inserted by editor auto-pairing.
  if token and trigger_char == "#" and token.text:find("[", 1, true)
    and ctx.line:sub(ctx.cursor[2] + 1, ctx.cursor[2] + 1) == "]" then
    edit_range["end"].character = edit_range["end"].character + 1
  end

  -- Slash commands
  if trigger_char == "/" then
    callback({
      context = ctx,
      is_incomplete_forward = false,
      is_incomplete_backward = false,
      items = vim
        .iter(completion.slash_commands(ctx.bufnr))
        :map(function(item)
          return {
            kind = vim.lsp.protocol.CompletionItemKind.Function,
            label = item.label:sub(2),
            textEdit = {
              newText = item.label,
              range = edit_range,
            },
            documentation = {
              kind = "plaintext",
              value = item.detail,
            },
            data = {
              type = "slash_command",
              from_prompt_library = item.from_prompt_library,
              config = item.config,
            },
          }
        end)
        :totable(),
    })

  -- Variables
  elseif trigger_char == "#" then
    callback({
      context = ctx,
      is_incomplete_forward = false,
      is_incomplete_backward = false,
      items = vim
        .iter(completion.variables(ctx.bufnr))
        :map(function(item)
          return {
            kind = vim.lsp.protocol.CompletionItemKind.Variable,
            label = item.label:sub(2),
            textEdit = {
              newText = item.label,
              range = edit_range,
            },
            documentation = {
              kind = "plaintext",
              value = item.detail,
            },
            data = { type = "variable" },
          }
        end)
        :totable(),
    })

  -- Tools
  elseif trigger_char == "@" then
    callback({
      context = ctx,
      is_incomplete_forward = false,
      is_incomplete_backward = false,
      items = vim
        .iter(completion.tools(ctx.bufnr))
        :map(function(item)
          return {
            kind = vim.lsp.protocol.CompletionItemKind.Struct,
            label = item.label:sub(2),
            textEdit = {
              newText = item.label,
              range = edit_range,
            },
            documentation = {
              kind = "plaintext",
              value = item.detail,
            },
            data = { type = "tool" },
          }
        end)
        :totable(),
    })

  -- Nothing to show
  else
    callback()
  end
end

function M:execute(ctx, item, callback, default_implementation)
  -- Literal mentions only need default text insertion.
  if item.data.type ~= "slash_command" then
    if type(default_implementation) == "function" then
      default_implementation()
    end

    return callback()
  end

  local chat = require("maxa").buf_get_chat(ctx.bufnr)
  local selected = vim.deepcopy(item)
  for key, value in pairs(selected.data) do
    selected[key] = value
  end
  local range = item.textEdit and item.textEdit.range
  local ok, err = completion.prepare_slash_command(selected, chat, ctx.bufnr, {
    start = { row = range and range.start.line, col = range and range.start.character },
    ["end"] = { row = range and range["end"].line, col = range and range["end"].character },
    revalidate_selection = true,
  })
  vim.bo[ctx.bufnr].buflisted = false

  if ok then
    completion.slash_commands_execute(selected, chat)
  else
    vim.notify("[Maxa AI] Could not prepare slash command: " .. tostring(err), vim.log.levels.ERROR)
  end

  callback()
end

return M
