local billing = require("maxa.session.status.billing")
local state = require("maxa.session.status.state")
local token_usage = require("maxa.session.token_usage")

local M = {}

local function as_number(value)
  if type(value) == "number" and value > 0 then
    return value
  end
  if type(value) == "string" then
    local n = tonumber(value)
    if n and n > 0 then
      return n
    end
  end
  return nil
end

local function format_number(value)
  local n = as_number(value)
  if not n then
    return nil
  end

  if n >= 1000000 then
    local v = n / 1000000
    if v >= 10 or v == math.floor(v) then
      return string.format("%.0fm", v)
    end
    return string.format("%.1fm", v)
  end

  if n >= 1000 then
    local v = n / 1000
    if v >= 100 or v == math.floor(v) then
      return string.format("%.0fk", v)
    end
    return string.format("%.1fk", v)
  end

  return tostring(math.floor(n))
end

local function adapter_label(chat_state)
  if type(chat_state) ~= "table" then
    return nil
  end

  local adapter = chat_state.adapter_display_name or chat_state.adapter_name
  local model = chat_state.model

  if type(adapter) ~= "string" or adapter == "" then
    return nil
  end

  if type(model) == "string" and model ~= "" then
    return adapter .. "(" .. model .. ")"
  end

  return adapter
end

local function token_percent_from_meta(chat)
  if type(chat) ~= "table" or type(chat._meta) ~= "table" then
    return nil
  end
  local status = chat._meta.maxa_ai_status
  return as_number(status and status.token_percent)
end

local function token_percent(chat, chat_state)
  local usage = token_usage.get_usage(chat, chat_state)
  if not usage then
    return token_percent_from_meta(chat)
  end
  token_usage.persist_status(chat, chat_state)
  return usage.percent
end

local function token_label(chat, chat_state)
  local percent = token_percent(chat, chat_state)
  if not percent then
    return "-"
  end
  return string.format("%d%%%%", percent)
end

local function active_chat()
  return state.get_display_chat()
end

local function interaction_chat()
  local bufnr = vim.api.nvim_get_current_buf()
  local ok, maxa_ai = pcall(require, "maxa")
  if ok and type(maxa_ai.buf_get_chat) == "function" then
    local ok_chat, chat = pcall(maxa_ai.buf_get_chat, bufnr)
    if ok_chat and type(chat) == "table" then
      return chat, { bufnr = bufnr, chat = chat }
    end
  end
  return state.get_active_chat()
end

local function write_status_meta(chat, chat_state)
  if type(chat) ~= "table" then
    return
  end
  local tokens = token_usage.get_token_count(chat, chat_state)
  local percent = token_percent(chat, chat_state)
  local max_tokens = token_usage.get_context_window(chat, chat_state)
  if not tokens and not percent and not max_tokens then
    return
  end

  chat._meta = chat._meta or {}
  local status = chat._meta.maxa_ai_status or {}
  if tokens then
    status.tokens = tokens
  end
  if percent then
    status.token_percent = percent
  end
  if max_tokens then
    status.context_limit = max_tokens
  end
  status.updated_at = os.time()
  chat._meta.maxa_ai_status = status
end

local function hl(group, text)
  if type(text) ~= "string" or text == "" then
    return ""
  end
  return string.format("%%#%s#%s", group, text)
end

local notify_highlights_ready = false

local function ensure_notify_highlights()
  if notify_highlights_ready then
    return
  end
  notify_highlights_ready = true

  local function fg_from(group, fallback)
    local ok, value = pcall(vim.api.nvim_get_hl, 0, { name = group, link = false })
    if ok and type(value) == "table" and value.fg then
      return value.fg
    end
    return fallback
  end

  vim.api.nvim_set_hl(0, "MaxaNotifyDefault", {
    fg = fg_from("Comment", 0x7f849c),
    italic = false,
  })
  vim.api.nvim_set_hl(0, "MaxaNotifyActive", {
    fg = fg_from("DiagnosticInfo", 0x89b4fa),
    italic = false,
  })
end

local function token_bracket(chat, chat_state)
  return "[" .. token_label(chat, chat_state) .. "]"
end

local function detail_status_parts()
  local chat, chat_state = state.get_display_chat()
  if not chat_state then
    return {}
  end
  write_status_meta(chat, chat_state)

  local parts = {}
  local label = adapter_label(chat_state)
  if label then
    table.insert(parts, label)
  end

  table.insert(parts, hl(M.token_hl_group(), token_bracket(chat, chat_state)))
  local metrics = require("maxa.adapters.metrics")
  table.insert(parts, hl("DiagnosticOk", metrics.format(metrics.adapter_status(chat_state.adapter_name))))

  local billing_parts = billing.parts(chat_state)
  if billing_parts.balance_text then
    table.insert(parts, hl(M.balance_hl_group(), "[" .. billing_parts.balance_text .. "]"))
  end
  if billing_parts.subscription_text then
    table.insert(parts, hl(M.subscription_hl_group(), "[" .. billing_parts.subscription_text .. "]"))
  end

  return parts
end

local function active_status_parts()
  local parts = { state.spinner() }
  local notify_icon = M.notify_icon()
  if notify_icon ~= "" then
    table.insert(parts, notify_icon)
  end
  vim.list_extend(parts, detail_status_parts())
  return parts
end

function M.status()
  return table.concat(active_status_parts(), " ")
end

function M.spinner_status()
  return state.spinner()
end

function M.details_status()
  return table.concat(detail_status_parts(), " ")
end

function M.base_status()
  local _, chat_state = active_chat()
  if not chat_state then
    return state.spinner()
  end

  local label = adapter_label(chat_state)
  if label then
    return state.spinner() .. " " .. label
  end
  return state.spinner()
end

function M.token_status()
  local chat, chat_state = active_chat()
  if not chat_state then
    return ""
  end
  return "[" .. token_label(chat, chat_state) .. "]"
end

function M.balance_status()
  local _, chat_state = active_chat()
  local parts = billing.parts(chat_state)
  if not parts.balance_text then
    return ""
  end
  return "[" .. parts.balance_text .. "]"
end

function M.subscription_status()
  local _, chat_state = active_chat()
  local parts = billing.parts(chat_state)
  if not parts.subscription_text then
    return ""
  end
  return "[" .. parts.subscription_text .. "]"
end

function M.cond()
  return true
end

function M.has_display_chat()
  local _, chat_state = state.get_display_chat()
  return chat_state ~= nil
end

function M.notify_icon()
  local chat = interaction_chat()
  if type(chat) ~= "table" then
    return ""
  end

  local ok, notify = pcall(require, "maxa.session.notify_when_done")
  if ok and notify.is_active(chat) then
    return "🔔"
  end
  return "🔕"
end

function M.notify_hl_group()
  ensure_notify_highlights()
  local chat = interaction_chat()
  if type(chat) ~= "table" then
    return "MaxaNotifyDefault"
  end

  local ok, notify = pcall(require, "maxa.session.notify_when_done")
  if ok and notify.is_active(chat) then
    return "MaxaNotifyActive"
  end
  return "MaxaNotifyDefault"
end

function M.toggle_notify()
  local chat = interaction_chat()
  local ok, notify = pcall(require, "maxa.session.notify_when_done")
  if not ok then
    vim.notify("[notify_when_done] 无法加载通知监听模块", vim.log.levels.WARN)
    return
  end

  if not chat then
    notify.toggle(chat)
    state.refresh()
    return
  end

  if notify.is_active(chat) then
    notify.disable(chat)
    vim.notify("[notify_when_done] 已取消当前会话监听", vim.log.levels.INFO)
    state.refresh()
    return
  end

  notify.enable(chat)
  state.refresh()
end

function M.hl_group()
  if state.is_busy() then
    return "DiagnosticInfo"
  end
  return "Comment"
end

function M.token_hl_group()
  local chat, chat_state = active_chat()
  local percent = token_percent(chat, chat_state)
  if not percent then
    return "Comment"
  end
  if percent >= 80 then
    return "DiagnosticError"
  end
  if percent >= 60 then
    return "DiagnosticWarn"
  end
  return "DiagnosticOk"
end

function M.balance_hl_group()
  local _, chat_state = active_chat()
  local parts = billing.parts(chat_state)
  local value = parts.balance_value
  if not value then
    return "Comment"
  end
  if value < 1 then
    return "DiagnosticError"
  end
  if value < 5 then
    return "DiagnosticWarn"
  end
  return "DiagnosticOk"
end

function M.subscription_hl_group()
  local _, chat_state = active_chat()
  local parts = billing.parts(chat_state)
  local remaining = parts.subscription_remaining
  local total = parts.subscription_total
  if not remaining or not total or total <= 0 then
    return "Comment"
  end
  local ratio = remaining / total
  if ratio < 0.1 then
    return "DiagnosticError"
  end
  if ratio < 0.25 then
    return "DiagnosticWarn"
  end
  return "DiagnosticOk"
end

function M.refresh()
  local _, chat_state = state.get_active_chat()
  billing.refresh(chat_state)
  state.refresh()
end

return M
