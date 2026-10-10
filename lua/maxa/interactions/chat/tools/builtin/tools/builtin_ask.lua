local coordinator = require("maxa.interactions.chat.tools.builtin.runtime.ask")

local M = {}

local ALLOWED_FIELDS = {
  mode = true,
  message = true,
  choices = true,
  photo = true,
  parse_mode = true,
  timeout = true,
}

local function char_length(value)
  return vim.fn.strchars(value)
end

local function nonblank(value)
  return type(value) == "string" and vim.trim(value) ~= ""
end

local function omit_json_nulls(params)
  local normalized = {}
  for key, value in pairs(params) do
    if value ~= vim.NIL then
      normalized[key] = value
    end
  end
  return normalized
end

local function validate_string(name, value, max_length, opts)
  opts = opts or {}
  if value == nil then
    if opts.min_length then
      return false, name .. " must not be empty"
    end
    return true
  end
  if type(value) ~= "string" then
    return false, name .. " must be a string"
  end
  local length = char_length(value)
  if opts.min_length and length < opts.min_length then
    return false, name .. " must not be empty"
  end
  if length > max_length then
    return false, string.format("%s must be at most %d characters", name, max_length)
  end
  return true
end

local function validate_choices(choices)
  if type(choices) ~= "table" or vim.islist(choices) == false or #choices < 1 or #choices > 20 then
    return nil, "choices must contain 1 to 20 nonempty rows"
  end

  local normalized = {}
  local values = {}
  local total = 0
  for row_index, row in ipairs(choices) do
    if type(row) ~= "table" or vim.islist(row) == false or #row < 1 then
      return nil, string.format("choices[%d] must be a nonempty row", row_index)
    end
    local normalized_row = {}
    for item_index, item in ipairs(row) do
      total = total + 1
      if total > 100 then
        return nil, "choices must contain at most 100 buttons"
      end
      if type(item) ~= "table" or vim.islist(item) then
        return nil, string.format("choices[%d][%d] must be an object", row_index, item_index)
      end
      for key in pairs(item) do
        if key ~= "label" and key ~= "value" then
          return nil,
            string.format("choices[%d][%d] contains unsupported field %s", row_index, item_index, tostring(key))
        end
      end
      local ok_label, label_err = validate_string("choice label", item.label, 64, { min_length = 1 })
      if not ok_label then
        return nil, label_err
      end
      local ok_value, value_err = validate_string("choice value", item.value, 256, { min_length = 1 })
      if not ok_value then
        return nil, value_err
      end
      if values[item.value] then
        return nil, "choice values must be unique"
      end
      values[item.value] = true
      table.insert(normalized_row, { label = item.label, value = item.value })
    end
    table.insert(normalized, normalized_row)
  end
  return normalized
end

function M.normalize(params)
  if type(params) ~= "table" or vim.islist(params) then
    return nil, "ask parameters must be an object"
  end
  for key in pairs(params) do
    if not ALLOWED_FIELDS[key] then
      return nil, "unsupported ask parameter: " .. tostring(key)
    end
  end
  params = omit_json_nulls(params)

  local mode = params.mode
  if mode ~= "notify" and mode ~= "input" and mode ~= "choice" then
    return nil, "mode must be one of notify, input, or choice"
  end

  local ok_message, message_err = validate_string("message", params.message, 4096)
  if not ok_message then
    return nil, message_err
  end
  local ok_photo, photo_err = validate_string("photo", params.photo, 2048)
  if not ok_photo then
    return nil, photo_err
  end
  if params.parse_mode ~= nil and params.parse_mode ~= "Markdown" and params.parse_mode ~= "HTML" then
    return nil, "parse_mode must be Markdown or HTML"
  end
  if params.timeout ~= nil then
    if
      type(params.timeout) ~= "number"
      or params.timeout ~= math.floor(params.timeout)
      or params.timeout < 0
      or params.timeout > 86400
    then
      return nil, "timeout must be an integer from 0 to 86400"
    end
  end

  if mode == "notify" then
    if not nonblank(params.message) and not nonblank(params.photo) then
      return nil, "notify requires message or photo"
    end
    if params.choices ~= nil then
      return nil, "choices is valid only for choice mode"
    end
    if params.timeout ~= nil then
      return nil, "timeout is valid only for input or choice mode"
    end
  else
    if not nonblank(params.message) then
      return nil, mode .. " requires a nonblank message"
    end
  end

  local choices = nil
  if mode == "choice" then
    choices, message_err = validate_choices(params.choices)
    if not choices then
      return nil, message_err
    end
  elseif params.choices ~= nil then
    return nil, "choices is valid only for choice mode"
  end

  return {
    mode = mode,
    message = params.message,
    choices = choices,
    photo = nonblank(params.photo) and params.photo or nil,
    parse_mode = params.parse_mode,
    timeout = (mode == "input" or mode == "choice") and (params.timeout == nil and 0 or params.timeout) or nil,
  }
end

local function run(context, response)
  local params, err = M.normalize(context and context.params)
  if not params then
    return response:error(err)
  end
  if type(context.chat) ~= "table" then
    return response:error("exact caller Chat is unavailable")
  end

  local started, start_err = coordinator.start(context.chat, params, function(ok, value)
    if ok then
      response:text(value):send()
    else
      response:error(value)
    end
  end, {
    tool_call_id = context.tool_call_id,
    ui = context.ui,
  })
  if not started then
    return response:error(start_err)
  end
end

return {
  name = "ask",
  interactive = true, -- local-only; every mode is prohibited inside a batch
  display = require("maxa.interactions.chat.tools.builtin.runtime.ask_display").display,
  description = [[Contact the user in the current Chat and Telegram when available; first valid reply wins. Telegram also receives the immediately preceding visible LLM response before this request, split completely when long; intervening user/tool messages prevent forwarding. Child input/choice requests also accept replies in the exact top-level Chat; async children relay only during active blocking wait. `notify`: one-way, not approval. `input`: text or one Telegram image. `choice`: buttons or text from any active entrance. Telegram failure leaves Chat available. Returns plain text; invalid requests, cancellation, timeout, lost caller Chat, or both channels failing are errors.]],
  inputSchema = {
    type = "object",
    additionalProperties = false,
    properties = {
      mode = { type = "string", enum = { "notify", "input", "choice" } },
      message = { type = "string", maxLength = 4096 },
      choices = {
        type = "array",
        minItems = 1,
        maxItems = 20,
        items = {
          type = "array",
          minItems = 1,
          items = {
            type = "object",
            additionalProperties = false,
            properties = {
              label = { type = "string", minLength = 1, maxLength = 64 },
              value = { type = "string", minLength = 1, maxLength = 256 },
            },
            required = { "label", "value" },
          },
        },
      },
      photo = { type = "string", maxLength = 2048 },
      parse_mode = { type = "string", enum = { "Markdown", "HTML" } },
      timeout = {
        type = "integer",
        minimum = 0,
        maximum = 86400,
        description = "Seconds; default 0 (wait for user). Set >0 only with a context-specific safe fallback; prefer at least 300 (5 min). Expiry is an error, not a default selection.",
      },
    },
    required = { "mode" },
  },
  run = run,
  _normalize = M.normalize,
}
