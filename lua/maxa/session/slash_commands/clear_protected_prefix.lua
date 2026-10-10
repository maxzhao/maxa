-- clear_protected_prefix: 清理当前或指定历史会话的 compact protected prefix
--
-- 用法：
--   /clear_protected_prefix
--   save_id: 20260607_144518 /clear_protected_prefix
--   20260607_144518 /clear_protected_prefix

local compaction_messages = require("maxa.session.compaction_messages")
local compact_utils = require("maxa.session.slash_commands.compact_utils")

---@class MaxaAI.SlashCommand.ClearProtectedPrefix: MaxaAI.SlashCommand
local SlashCommand = {}

---@param args MaxaAI.SlashCommandArgs
function SlashCommand.new(args)
  local self = setmetatable({
    Chat = args.Chat,
    config = args.config,
    context = args.context,
  }, { __index = SlashCommand })

  return self
end

local function extract_target_save_id(chat, context)
  local instructions = compact_utils.extract_slash_command_instructions(chat, context, "clear_protected_prefix")
  instructions = vim.trim(instructions or "")
  if instructions == "" then
    return nil
  end

  local save_id = instructions:match("save_id:%s*`?([%w_%-]+)`?")
    or instructions:match("^`?([%w_%-]+)`?$")
  return save_id
end

local function clear_chat(chat)
  if type(chat) ~= "table" then
    return nil, "No active chat found"
  end

  local old_count = compaction_messages.get_protected_prefix_count(chat)
  compaction_messages.set_protected_prefix_count(chat, 0)

  local history_api = compact_utils.get_history_api()
  if history_api and type(history_api.save_chat) == "function" and chat.opts and chat.opts.save_id then
    history_api.save_chat(chat)
  end

  return {
    target = "current",
    save_id = chat.opts and chat.opts.save_id or nil,
    old_count = old_count,
    new_count = 0,
  }, nil
end

local function save_chat_data(history_api, chat_data)
  if type(history_api._save_chat_to_file) == "function" then
    local result = history_api._save_chat_to_file(chat_data)
    if result and result.ok == false then
      return false, result.error or "Failed to save chat data"
    end
    return true, nil
  end

  if type(history_api.save_chat) == "function" then
    local chat_obj = {
      opts = {
        save_id = chat_data.save_id,
        title = chat_data.title,
        cwd = chat_data.cwd,
        title_refresh_count = chat_data.title_refresh_count or 0,
        compact_protected_prefix_count = 0,
      },
      _compact_protected_prefix_count = 0,
      _meta = vim.deepcopy(chat_data._meta or {}),
      messages = chat_data.messages or {},
      settings = vim.deepcopy(chat_data.settings or {}),
      adapter = { name = chat_data.adapter or "unknown" },
      context_items = chat_data.context_items or {},
      tool_registry = {
        schemas = chat_data.schemas or {},
        in_use = chat_data.in_use or {},
      },
      cycle = chat_data.cycle or 1,
    }
    history_api.save_chat(chat_obj)
    return true, nil
  end

  return false, "History API does not expose a save method"
end

local function clear_saved(save_id)
  local history_api = compact_utils.get_history_api()
  if not history_api then
    return nil, "History extension not available"
  end
  if type(history_api.load_chat) ~= "function" then
    return nil, "History API missing load_chat"
  end

  local chat_data = history_api.load_chat(save_id)
  if not chat_data then
    return nil, "Session not found: " .. tostring(save_id)
  end

  local old_count = compaction_messages.get_protected_prefix_count(chat_data)
  chat_data.compact_protected_prefix_count = 0
  chat_data._compact_protected_prefix_count = nil
  chat_data.opts = chat_data.opts or {}
  chat_data.opts.compact_protected_prefix_count = 0

  local ok, err = save_chat_data(history_api, chat_data)
  if not ok then
    return nil, err
  end

  return {
    target = "saved",
    save_id = save_id,
    old_count = old_count,
    new_count = 0,
  }, nil
end

---@param SlashCommands MaxaAI.SlashCommands
---@return nil
function SlashCommand:execute(SlashCommands)
  local target_save_id = extract_target_save_id(self.Chat, self.context)
  local result, err

  if target_save_id then
    result, err = clear_saved(target_save_id)
  else
    result, err = clear_chat(self.Chat)
  end

  if err then
    vim.notify("[clear_protected_prefix] " .. tostring(err), vim.log.levels.ERROR)
    return
  end

  vim.notify(
    string.format(
      "[clear_protected_prefix] cleared %s protected prefix: save_id=%s, old=%d, new=%d",
      result.target,
      tostring(result.save_id or "(none)"),
      tonumber(result.old_count) or 0,
      tonumber(result.new_count) or 0
    ),
    vim.log.levels.INFO
  )
end

return SlashCommand
