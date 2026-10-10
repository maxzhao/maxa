local session_trace = require("maxa.session.session_trace")
local history_core = require("maxa.session.history_core")
local history_session = require("maxa.session.history_session")

---@class MaxaAI.SlashCommand.TraceStart: MaxaAI.SlashCommand
local SlashCommand = {}

---@param args MaxaAI.SlashCommandArgs
function SlashCommand.new(args)
  return setmetatable({
    Chat = args.Chat,
    config = args.config,
    context = args.context,
  }, { __index = SlashCommand })
end

local function notify(message, level)
  vim.notify("[trace_start] " .. message, level or vim.log.levels.INFO)
end

local function get_active_chat(fallback)
  local ok_cc, maxa_ai = pcall(require, "maxa")
  if ok_cc and type(maxa_ai.buf_get_chat) == "function" then
    local ok_chat, chat = pcall(maxa_ai.buf_get_chat, 0)
    if ok_chat and type(chat) == "table" then
      return chat
    end
  end
  local ok_chat_mod, chat_mod = pcall(require, "maxa.interactions.chat")
  if ok_chat_mod and type(chat_mod.buf_get_chat) == "function" then
    local ok_chat, chat = pcall(chat_mod.buf_get_chat, 0)
    if ok_chat and type(chat) == "table" then
      return chat
    end
  end
  return fallback
end

local function ensure_regular_save_id(chat)
  chat.opts = chat.opts or {}
  local save_id = chat.opts.save_id
  if type(save_id) == "string" and save_id ~= "" then
    local _, err = session_trace.validate_trace_id(save_id)
    if err then
      return nil, "current chat save_id is not trace-root safe: " .. err
    end
    if history_core.is_unsavable_save_id(save_id) then
      return nil, "current chat is an unsavable temporary session"
    end
    return save_id, nil
  end

  save_id = history_core.generate_save_id()
  chat.opts.save_id = save_id
  return save_id, nil
end

local function save_chat(chat)
  local history_api = history_session.get_history_api()
  if history_api and type(history_api.save_chat) == "function" then
    history_api.save_chat(chat)
    return true
  end
  return false
end

---@param SlashCommands MaxaAI.SlashCommands
function SlashCommand:execute(SlashCommands)
  local chat = get_active_chat(self.Chat)
  if not chat then
    notify("No active chat", vim.log.levels.ERROR)
    return
  end

  local root_trace_id, id_err = ensure_regular_save_id(chat)
  if not root_trace_id then
    notify(id_err, vim.log.levels.ERROR)
    return
  end

  local existing = session_trace.get_membership(chat)
  if existing and existing.root_trace_id and existing.root_trace_id ~= root_trace_id then
    notify(
      string.format("Current chat already belongs to root trace %s; root_trace_id is immutable", existing.root_trace_id),
      vim.log.levels.ERROR
    )
    return
  end

  local title = chat.opts and chat.opts.title or chat.title
  local manifest, manifest_err = session_trace.ensure_manifest(root_trace_id, {
    root_save_id = root_trace_id,
    root_title = title,
    source = "trace_start",
    status = "active",
  })
  if not manifest then
    notify("Failed to create trace manifest: " .. tostring(manifest_err), vim.log.levels.ERROR)
    return
  end
  if title and manifest.root_title ~= title then
    session_trace.update_manifest(root_trace_id, { root_title = title })
  end

  local membership = existing or session_trace.create_root_membership(root_trace_id)
  membership.session_role = "root"
  membership.root_trace_id = root_trace_id
  membership.root_save_id = root_trace_id
  membership.active = true
  local stored_membership, membership_err = session_trace.set_membership(chat, membership)
  if not stored_membership then
    notify("Failed to set trace membership: " .. tostring(membership_err), vim.log.levels.ERROR)
    return
  end

  local started_event = {
    root_trace_id = root_trace_id,
    kind = "trace.started",
    span_id = stored_membership.span_id,
    parent_span_id = stored_membership.parent_span_id,
    session = session_trace.session_info(chat, stored_membership),
    trace = {
      root_trace_id = root_trace_id,
      root_save_id = root_trace_id,
      root_title = title,
    },
    dedupe_key = "trace.started:" .. root_trace_id,
  }
  local started_result, started_err = session_trace.append_event(root_trace_id, started_event)
  if not started_result then
    notify("Failed to append trace.started: " .. tostring(started_err), vim.log.levels.ERROR)
    return
  end
  if started_result.event_id and not stored_membership.source_event_id then
    stored_membership.source_event_id = started_result.event_id
    session_trace.set_membership(chat, stored_membership)
  end

  local backfill = session_trace.backfill_chat(root_trace_id, chat, { membership = stored_membership })
  local saved = save_chat(chat)

  local msg = string.format(
    "Trace %s active; backfill added %d, skipped %d%s",
    root_trace_id,
    backfill.added or 0,
    backfill.skipped or 0,
    saved and "" or "; warning: history API unavailable, membership not saved yet"
  )
  if backfill.errors and #backfill.errors > 0 then
    msg = msg .. string.format("; %d backfill errors", #backfill.errors)
    notify(msg, vim.log.levels.WARN)
  else
    notify(msg, vim.log.levels.INFO)
  end
end

return SlashCommand
