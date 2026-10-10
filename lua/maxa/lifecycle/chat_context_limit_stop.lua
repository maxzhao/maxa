-- chat_context_limit_stop: one-shot context usage limit with soft-stop boundaries.
--
-- This hook does not cancel active requests or tools. When the configured
-- context usage target is reached, it requests chat_soft_stop so the current
-- response/tool batch drains before automatic continuation is suppressed.

local M = {}

local ACTIVE_KEY = "_maxa_context_limit_stop_active"
local PROMPTING_KEY = "_maxa_context_limit_stop_prompting"
local TARGET_RATIO_KEY = "_maxa_context_limit_stop_target_ratio"
local TARGET_PERCENT_KEY = "_maxa_context_limit_stop_target_percent"
local TRIGGERED_KEY = "_maxa_context_limit_stop_triggered"
local READY_CALLBACK_KEY = "_maxa_context_limit_stop_ready_callback_installed"

local EPSILON = 1e-9

local function notify(message, level)
  vim.notify(message, level or vim.log.levels.INFO)
end

local function get_usage(chat)
  local ok, token_usage = pcall(require, "maxa.session.token_usage")
  if not ok or type(token_usage) ~= "table" or type(token_usage.get_usage) ~= "function" then
    return nil
  end
  local ok_usage, usage = pcall(token_usage.get_usage, chat, nil)
  if not ok_usage or type(usage) ~= "table" then
    return nil
  end
  if type(usage.tokens) ~= "number" or type(usage.context_window) ~= "number" or type(usage.ratio) ~= "number" then
    return nil
  end
  return usage
end

local function usage_percent(usage)
  return (usage.ratio or 0) * 100
end

local function format_percent(value)
  if math.abs(value - math.floor(value + 0.5)) < 0.005 then
    return string.format("%d%%", math.floor(value + 0.5))
  end
  return string.format("%.2f%%", value)
end

local function soft_stop_module()
  local ok, soft_stop = pcall(require, "maxa.lifecycle.chat_soft_stop")
  if ok and type(soft_stop) == "table" then
    return soft_stop
  end
  return nil
end

local function is_busy(chat)
  local soft_stop = soft_stop_module()
  if soft_stop and type(soft_stop.is_busy) == "function" then
    local ok, busy = pcall(soft_stop.is_busy, chat)
    if ok then
      return busy == true
    end
  end
  return type(chat) == "table"
    and (chat.current_request ~= nil or chat.current_tool ~= nil or (type(chat.tools) == "table" and chat.tools.tool ~= nil))
end

local function call_callback(opts)
  if type(opts) ~= "table" or type(opts.callback) ~= "function" then
    return true
  end
  local ok, err = pcall(opts.callback)
  if not ok then
    notify("[context-limit-stop] auto-submit callback failed: " .. tostring(err), vim.log.levels.ERROR)
  end
  return ok
end

local function soft_stop_is_requested(chat)
  local soft_stop = soft_stop_module()
  if soft_stop and type(soft_stop.is_requested) == "function" then
    local ok, requested = pcall(soft_stop.is_requested, chat)
    return ok and requested == true
  end
  return false
end

local function ensure_ready_callback(chat)
  if type(chat) ~= "table" or chat[READY_CALLBACK_KEY] == true then
    return
  end
  if type(chat.add_callback) ~= "function" then
    return
  end

  chat[READY_CALLBACK_KEY] = true
  chat:add_callback("on_ready", function(self_chat)
    M.check(self_chat, "ready")
  end)
  chat:add_callback("on_closed", function(self_chat)
    M.clear(self_chat, "closed")
  end)
  chat:add_callback("on_cancelled", function(self_chat)
    M.clear(self_chat, "cancelled")
  end)
end

local function parse_input(input)
  if type(input) ~= "string" then
    return nil, "Context limit input is required."
  end
  local trimmed = vim.trim(input)
  if trimmed == "" then
    return nil, "Context limit input is required."
  end

  local relative = false
  local number_text = trimmed
  if trimmed:sub(1, 1) == "+" then
    relative = true
    number_text = vim.trim(trimmed:sub(2))
  end

  if number_text == "" then
    return nil, "Context limit must be a number."
  end

  local value = tonumber(number_text)
  if not value then
    return nil, "Context limit must be a number."
  end
  if value < 0 then
    return nil, "Context limit cannot be negative."
  end

  if not relative and value > 100 then
    return nil, "Context limit must be between 0 and 100."
  end

  return { relative = relative, value = value, raw = trimmed }, nil
end

local function target_from_input(input, usage)
  local parsed, err = parse_input(input)
  if not parsed then
    return nil, err
  end

  local current_percent = usage_percent(usage)
  local target_percent
  if parsed.relative then
    target_percent = current_percent + parsed.value
    if target_percent > 100 + EPSILON then
      return nil,
        string.format(
          "Context limit %s would exceed 100%%: current %s + %.2f%% = %s.",
          parsed.raw,
          format_percent(current_percent),
          parsed.value,
          format_percent(target_percent)
        )
    end
  else
    target_percent = parsed.value
    if (target_percent / 100) + EPSILON < usage.ratio then
      return nil,
        string.format(
          "Context limit %s is below current usage %s.",
          format_percent(target_percent),
          format_percent(current_percent)
        )
    end
  end

  return {
    ratio = target_percent / 100,
    percent = target_percent,
    current_percent = current_percent,
    relative = parsed.relative,
    raw = parsed.raw,
  }, nil
end

function M.is_active(chat)
  return type(chat) == "table" and (chat[ACTIVE_KEY] == true or chat[PROMPTING_KEY] == true)
end

function M.clear(chat, reason)
  if type(chat) ~= "table" then
    return false
  end
  local was_active = chat[ACTIVE_KEY] == true or chat[PROMPTING_KEY] == true
  chat[ACTIVE_KEY] = nil
  chat[PROMPTING_KEY] = nil
  chat[TARGET_RATIO_KEY] = nil
  chat[TARGET_PERCENT_KEY] = nil
  if reason ~= "triggered" then
    chat[TRIGGERED_KEY] = nil
  end
  return was_active
end

function M.arm(chat, input)
  if type(chat) ~= "table" then
    notify("[context-limit-stop] No Maxa AI chat is available", vim.log.levels.WARN)
    return false
  end

  local usage = get_usage(chat)
  if not usage then
    M.clear(chat, "usage_unavailable")
    notify("Context limit stop unavailable: current token usage or context window cannot be computed.", vim.log.levels.WARN)
    return false
  end

  local target, err = target_from_input(input, usage)
  if not target then
    M.clear(chat, "invalid_input")
    notify(err, vim.log.levels.ERROR)
    return false
  end

  ensure_ready_callback(chat)
  chat[ACTIVE_KEY] = true
  chat[PROMPTING_KEY] = nil
  chat[TARGET_RATIO_KEY] = target.ratio
  chat[TARGET_PERCENT_KEY] = target.percent
  chat[TRIGGERED_KEY] = nil

  notify(
    string.format(
      "Context limit stop armed at %s (current %s).",
      format_percent(target.percent),
      format_percent(target.current_percent)
    )
  )

  M.check(chat, "armed")
  return true
end

function M.toggle(chat)
  if type(chat) ~= "table" then
    notify("[context-limit-stop] No Maxa AI chat is available", vim.log.levels.WARN)
    return false
  end

  if chat[ACTIVE_KEY] == true or chat[PROMPTING_KEY] == true then
    M.clear(chat, "toggle")
    notify("Context limit stop cancelled.")
    return false
  end

  chat[PROMPTING_KEY] = true
  vim.ui.input({
    prompt = "Context limit percent (0-100 or +N): ",
  }, function(input)
    if type(chat) ~= "table" or chat[PROMPTING_KEY] ~= true then
      return
    end
    if input == nil then
      M.clear(chat, "input_cancelled")
      return
    end
    M.arm(chat, input)
  end)
  return true
end

function M.check(chat, reason)
  if type(chat) ~= "table" or chat[ACTIVE_KEY] ~= true then
    return false
  end
  if chat[TRIGGERED_KEY] == true then
    return false
  end

  local target_ratio = chat[TARGET_RATIO_KEY]
  if type(target_ratio) ~= "number" then
    M.clear(chat, "missing_target")
    return false
  end

  local usage = get_usage(chat)
  if not usage then
    return false
  end
  if usage.ratio + EPSILON < target_ratio then
    return false
  end

  local target_percent = chat[TARGET_PERCENT_KEY] or target_ratio * 100
  chat[TRIGGERED_KEY] = true
  chat[ACTIVE_KEY] = nil
  chat[PROMPTING_KEY] = nil
  chat[TARGET_RATIO_KEY] = nil
  chat[TARGET_PERCENT_KEY] = nil

  local message = string.format(
    "Context limit reached: current %s >= limit %s.",
    format_percent(usage_percent(usage)),
    format_percent(target_percent)
  )

  local soft_stop = soft_stop_module()
  if is_busy(chat) and soft_stop and type(soft_stop.request) == "function" then
    if type(soft_stop.is_requested) ~= "function" or not soft_stop.is_requested(chat) then
      local ok, err = pcall(soft_stop.request, chat)
      if not ok then
        notify("[context-limit-stop] soft stop request failed: " .. tostring(err), vim.log.levels.ERROR)
        return false
      end
    end
    notify(message .. " Soft stop requested after current operation.")
    return true
  end

  notify(message .. " Listener completed.")
  return true
end

function M.before_submit(chat, opts)
  local reached = M.check(chat, "submit")
  if reached and type(opts) == "table" and opts.auto_submit == true and not soft_stop_is_requested(chat) then
    call_callback(opts)
    return false
  end
  return true
end

function M.before_tools_done(chat, opts)
  local reached = M.check(chat, "tools_done")
  if reached and type(opts) == "table" and opts.auto_submit == true and not soft_stop_is_requested(chat) then
    local converted = vim.deepcopy(opts)
    converted.auto_submit = false
    return converted
  end
  return opts
end

function M.setup()
end

function M._test_reset_patch()
end

function M._test_keys()
  return {
    active = ACTIVE_KEY,
    prompting = PROMPTING_KEY,
    target_ratio = TARGET_RATIO_KEY,
    target_percent = TARGET_PERCENT_KEY,
    triggered = TRIGGERED_KEY,
    ready_callback = READY_CALLBACK_KEY,
  }
end

function M._test_parse(input, usage)
  usage = usage or { ratio = 0.25, tokens = 25, context_window = 100 }
  return target_from_input(input, usage)
end

return M
