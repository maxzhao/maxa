-- Session trace lifecycle hooks for tracked Maxa AI chats.
--
-- Captures natural turn events only when a chat already has
-- _meta.session_trace membership. This module is observational: it never
-- submits, injects, removes, or mutates chat messages.

local session_trace = require("maxa.session.session_trace")

local M = {}

local installed = false
local MARKER_KEY = "_session_trace_submit_marker"
local STOPPED_KEY = "_session_trace_stopped_turn"

local function now()
  return os.time()
end

local function event_data(args)
  return type(args) == "table" and type(args.data) == "table" and args.data or {}
end

local function get_chat_from_event(args)
  local data = event_data(args)
  local bufnr = data.bufnr
  if not bufnr then
    return nil
  end
  local ok, chat_mod = pcall(require, "maxa.interactions.chat")
  if not ok or type(chat_mod.buf_get_chat) ~= "function" then
    return nil
  end
  local ok_chat, chat = pcall(chat_mod.buf_get_chat, bufnr)
  if ok_chat then
    return chat
  end
  return nil
end

local function tracked_membership(chat)
  local membership = session_trace.get_membership(chat)
  if type(membership) ~= "table" or membership.active == false or not membership.root_trace_id then
    return nil
  end
  return membership
end

local function message_role(msg)
  if type(msg) ~= "table" then
    return nil
  end
  if msg.role == "llm" then
    return "assistant"
  end
  return msg.role
end

local function is_visible_turn(msg, wanted_role)
  if type(session_trace.is_visible_natural_turn_message) == "function" then
    if not session_trace.is_visible_natural_turn_message(msg) then
      return false
    end
  elseif not (session_trace._test and session_trace._test.is_visible_conversation_message(msg)) then
    return false
  end
  return not wanted_role or message_role(msg) == wanted_role
end

local function find_manual_user_message(chat, marker)
  local messages = chat and chat.messages or {}
  local start_index = math.max(1, tonumber(marker and marker.before_message_count or 0) + 1)
  local expected = marker and marker.user_message or nil
  local latest_index, latest_msg

  for index = #messages, start_index, -1 do
    local msg = messages[index]
    if is_visible_turn(msg, "user") then
      latest_index, latest_msg = index, msg
      if type(expected) ~= "string" or expected == "" then
        break
      end
      local content = session_trace._test and session_trace._test.normalize_content(msg.content) or tostring(msg.content or "")
      if content == expected or vim.trim(content) == vim.trim(expected) then
        break
      end
    end
  end

  return latest_msg, latest_index
end

local function find_last_visible_assistant(chat)
  local messages = chat and chat.messages or {}
  for index = #messages, 1, -1 do
    local msg = messages[index]
    if is_visible_turn(msg, "assistant") then
      return msg, index
    end
  end
  return nil, nil
end

local function append_turn(chat, membership, msg, index, opts)
  opts = opts or {}
  membership = membership or tracked_membership(chat)
  if not membership then
    return nil, "chat has no active trace membership"
  end
  local root_trace_id = membership.root_trace_id
  local event = session_trace.message_to_turn_event(root_trace_id, chat, membership, msg, index, opts)
  if not event then
    return nil, "message is not a natural turn"
  end
  event.capture = vim.tbl_extend("force", event.capture or {}, {
    source = opts.source or "session_trace_lifecycle",
    manual_submit = opts.manual_submit == true or nil,
  })
  local result, err = session_trace.append_event(root_trace_id, event)
  if result and result.event_id then
    chat._session_trace_last_turn_event = {
      event_id = result.event_id,
      kind = event.kind,
      message_index = event.message and event.message.message_index or index,
      content_hash = event.message and session_trace.hash(event.message.content or "") or nil,
      appended = result.appended == true,
      duplicate = result.duplicate == true,
    }
  end
  return result, err
end

function M.mark_submit(chat, submit_info)
  if type(chat) ~= "table" then
    return
  end
  submit_info = submit_info or {}
  if submit_info.is_user_input ~= true or submit_info.auto_submit == true then
    chat[MARKER_KEY] = nil
    return
  end
  chat[MARKER_KEY] = {
    chat_id = chat.id,
    bufnr = chat.bufnr,
    user_message = submit_info.user_message or "",
    is_user_input = true,
    auto_submit = false,
    before_message_count = #(chat.messages or {}),
    created_at = now(),
  }
end

local function capture_submitted(chat)
  local marker = chat and chat[MARKER_KEY]
  if type(marker) ~= "table" or marker.is_user_input ~= true or marker.auto_submit == true then
    return nil
  end
  chat[MARKER_KEY] = nil

  local membership = tracked_membership(chat)
  if not membership then
    return nil
  end

  local msg, index = find_manual_user_message(chat, marker)
  if not msg then
    return nil, "manual submit marker found no visible user message"
  end
  return append_turn(chat, membership, msg, index, {
    source = "MaxaAIChatSubmitted",
    manual_submit = true,
  })
end

local function capture_stopped(chat)
  local membership = tracked_membership(chat)
  if not membership then
    return nil
  end
  chat[MARKER_KEY] = nil

  local messages = chat.messages or {}
  local index = #messages + 1
  chat[STOPPED_KEY] = {
    message_index = index,
    created_at = now(),
  }

  return append_turn(chat, membership, { role = "assistant", content = "" }, index, {
    source = "MaxaAIChatStopped",
    error = true,
    status = "stopped",
    reason = "user_stopped",
  })
end

local function capture_done(chat)
  local membership = tracked_membership(chat)
  if not membership then
    return nil
  end

  local stopped = chat[STOPPED_KEY]
  if stopped then
    chat[STOPPED_KEY] = nil
    return nil
  end

  if chat.status == "error" then
    local msg, index = find_last_visible_assistant(chat)
    if not msg then
      index = #(chat.messages or {}) + 1
      msg = { role = "assistant", content = "" }
    end
    return append_turn(chat, membership, msg, index, {
      source = "MaxaAIChatDone",
      error = true,
      status = "error",
      reason = chat._last_http_error or chat._last_error or "llm_error",
    })
  end

  local msg, index = find_last_visible_assistant(chat)
  if not msg then
    return nil
  end
  return append_turn(chat, membership, msg, index, {
    source = "MaxaAIChatDone",
  })
end

local function schedule_done_capture(args)
  vim.defer_fn(function()
    vim.schedule(function()
      local chat = get_chat_from_event(args)
      if chat then
        capture_done(chat)
      end
    end)
  end, 20)
end

function M.setup()
  if installed then
    return
  end
  installed = true

  local group = vim.api.nvim_create_augroup("MaxaSessionSessionTraceLifecycle", { clear = true })

  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "MaxaAIChatSubmitted",
    callback = function(args)
      local chat = get_chat_from_event(args)
      if chat then
        capture_submitted(chat)
      end
    end,
  })

  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "MaxaAIChatStopped",
    callback = function(args)
      local chat = get_chat_from_event(args)
      if chat then
        capture_stopped(chat)
      end
    end,
  })

  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "MaxaAIChatDone",
    callback = schedule_done_capture,
  })
end

M._test = {
  MARKER_KEY = MARKER_KEY,
  STOPPED_KEY = STOPPED_KEY,
  capture_submitted = capture_submitted,
  capture_done = capture_done,
  capture_stopped = capture_stopped,
  find_manual_user_message = find_manual_user_message,
  find_last_visible_assistant = find_last_visible_assistant,
  is_visible_turn = is_visible_turn,
}

return M
