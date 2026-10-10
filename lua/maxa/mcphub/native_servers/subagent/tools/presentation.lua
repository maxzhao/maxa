-- Local SubAgent answer/routing views and one-level live-summary binding.
local M = {}
local payload = require("maxa.mcphub.native_servers.subagent.result_format").parse
local function context_text(tokens)
  local percent = tokens and tokens.percent
  if type(percent) ~= "number" then return "◔ —" end
  return "◔ " .. (tokens.source == "estimated" and "~" or "") .. tostring(percent) .. "%"
end
function M.answer(name)
  return function(args, result)
    local title = type(args.title) == "string" and args.title or ""
    local view = { summary = title ~= "" and (name .. ' "' .. title:gsub("[\r\n]", " ") .. '"') or name, blocks = {} }
    local data = result and payload(result.text)
    if data and data.context_status then view.right = context_text(data.context_status.tokens) end
    if result and result.ok and data and type(data.content) == "string" and data.content ~= "" then
      view.blocks[1] = { kind = "fold", title = view.summary, content = data.content }
    end
    return view
  end
end
function M.handoff(args, result)
  local data = result and result.ok and payload(result.text)
  local text = "📩 " .. tostring(args.target or "?") .. ": " .. tostring(args.message or "")
  if data and data.content then
    text = data.content
    if data.private_message_from then text = "📩 From " .. data.private_message_from .. "\n\n" .. text end
  elseif data and data.private_message_from and data.private_message_from ~= "" and data.private_message then
    text = "📩 From " .. data.private_message_from .. ": " .. data.private_message
  elseif data and data.status == "session_ended" then
    text = "session_ended"
  end
  return { summary = false, progress = false, blocks = result and result.ok and {
    { kind = "markdown", content = "---\n\n" .. text .. "\n\n---" },
  } or {} }
end
function M.bind(chat, ui)
  if not ui then return function() end end
  local display = require("maxa.interactions.chat.tools.display")
  display.link_chat(ui, chat)
  local latest, stopped = 0, false
  local usage = require("maxa.session.token_usage")
  local status = require("maxa.session.session_status")
  local function refresh_context()
    if stopped or not ui.right then return end
    local current = usage.get_usage(chat)
    if current then
      ui:right(context_text({ percent = current.percent, source = "actual" }))
    else
      local current_status = status.from_chat(chat)
      ui:right(context_text(current_status and {
        percent = current_status.token_percent, source = current_status.token_source,
      }))
    end
  end
  local stop_usage = usage.observe(chat, refresh_context)
  local model_event = vim.api.nvim_create_autocmd("User", {
    pattern = { "MaxaAIChatModel", "MaxaAIChatAdapter" },
    callback = function(event)
      if event.data and event.data.bufnr == chat.bufnr then refresh_context() end
    end,
  })
  refresh_context()
  local unsubscribe = display.observe_tool_display(chat, function(event)
    if stopped or event.start_order < latest then return end
    latest = event.start_order
    ui:detail(event.summary)
  end)
  local function close()
    if stopped then return end
    refresh_context()
    stopped = true
    stop_usage()
    pcall(vim.api.nvim_del_autocmd, model_event)
    unsubscribe()
    ui:detail(nil)
  end
  display.on_terminal(ui, close)
  return close
end
return M
