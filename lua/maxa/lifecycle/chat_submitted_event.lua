-- Emit ChatSubmitted AbilityHook events for manual and programmatic Chat submissions.
local M = {}

local function parse_pending_user_message(chat)
  if not chat or not chat.header_line then
    return nil
  end
  local ok, parser = pcall(require, "maxa.interactions.chat.parser")
  if not ok or not parser.messages then
    return nil
  end
  local ok_msg, message = pcall(parser.messages, chat, chat.header_line)
  if not ok_msg or type(message) ~= "table" then
    return nil
  end
  local content = message.content
  if type(content) ~= "string" or vim.trim(content) == "" then
    return nil
  end
  return content
end

local function has_programmatic_submit_state(chat)
  return chat and (chat._repeat_state ~= nil or chat._auto_compact_in_progress == true)
end

local function classify_submit(chat, opts)
  opts = opts or {}
  local auto_submit = opts.auto_submit == true
  local pending_user_message
  local is_user_input = false
  if not auto_submit and not opts.regenerate and not opts.callback and not has_programmatic_submit_state(chat) then
    pending_user_message = parse_pending_user_message(chat)
    is_user_input = pending_user_message ~= nil
  end
  return {
    auto_submit = auto_submit,
    is_user_input = is_user_input,
    user_message = is_user_input and pending_user_message or "",
  }
end

local function mark_session_trace_submit(chat, submit_info)
  local ok, lifecycle = pcall(require, "maxa.lifecycle.session_trace_lifecycle")
  if ok and lifecycle and type(lifecycle.mark_submit) == "function" then
    lifecycle.mark_submit(chat, submit_info)
  end
end

local function fire_chat_submitted(chat, submit_info)
  if not chat then
    return
  end
  mark_session_trace_submit(chat, submit_info)
  local fire_ok, fire = pcall(require, "maxa.abilities.hooks.fire")
  if not fire_ok then
    return
  end
  local data = {
    bufnr = chat.bufnr,
    chat_id = chat.id,
    user_message = submit_info.user_message or "",
    is_user_input = submit_info.is_user_input == true,
    auto_submit = submit_info.auto_submit == true,
  }
  fire.fire_sync("ChatSubmitted", vim.deepcopy(data))
  fire.fire("ChatSubmitted", data)
end

function M.normalize_message(chat, data, opts)
  opts = opts or { visible = true }
  if data and data.role == "system" and chat and chat.messages and #chat.messages > 0 then
    local has_non_system = vim.iter(chat.messages):any(function(message)
      return message.role ~= "system"
    end)
    if has_non_system then
      local tag = opts._meta and opts._meta.tag
      if tag == "rules" then
        data = vim.deepcopy(data)
        data.role = "user"
      else
        error("OpenAI Responses message order violation: dynamic system messages are forbidden after the session starts")
      end
    end
  end
  return data, opts
end

function M.before_submit(chat, opts)
  opts = opts or {}
  local decision = package.loaded["maxa.lifecycle.chat_token_threshold_decision"]
  if decision and decision.blocks_submit(chat, opts) then
    return false
  end
  local submit_info = classify_submit(chat, opts)
  if submit_info.is_user_input then require("maxa.session.agent_identity").touch_dialogue(chat) end
  fire_chat_submitted(chat, submit_info)
  return true
end

function M.setup()
  return true
end

return M
