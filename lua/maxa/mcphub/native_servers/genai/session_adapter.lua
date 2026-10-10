-- Chat-local media overrides live on a system message's persisted metadata.
-- History and both compaction filters already preserve system messages.
local M = {}
local MEDIA = { image = true, tts = true, video = true }
local KEY = "genai_default_adapters"

local function carrier(chat)
  for _, message in ipairs(chat and chat.messages or {}) do
    if message.role == "system" and message._meta and message._meta[KEY] then
      return message
    end
  end
end

function M.get(chat, medium)
  local message = carrier(chat)
  local defaults = message and message._meta[KEY]
  return type(defaults) == "table" and defaults[medium] or nil
end

function M.set(chat, medium, adapter)
  if not MEDIA[medium] then
    return false, "medium must be one of: image, tts, video"
  end
  if not chat or type(chat.messages) ~= "table" then
    return false, "No active chat session"
  end
  local message = carrier(chat)
  if adapter ~= nil then
    local declaration = require("maxa.mcphub.native_servers.genai.capability_registry").get(adapter)
    if not declaration or not declaration.capabilities[medium] then
      return false, "adapter does not provide " .. medium .. " capability: " .. tostring(adapter)
    end
    if not message then
      for _, candidate in ipairs(chat.messages) do
        if candidate.role == "system" then
          message = candidate
          break
        end
      end
    end
    if not message then
      message = { role = "system", content = "Session media adapter settings.", opts = { visible = false } }
      table.insert(chat.messages, 1, message)
      local prefix = require("maxa.session.compaction_messages")
      prefix.set_protected_prefix_count(chat, prefix.get_protected_prefix_count(chat) + 1)
    end
    message._meta = message._meta or {}
    message._meta[KEY] = message._meta[KEY] or {}
    message._meta[KEY][medium] = adapter
  elseif message then
    message._meta[KEY][medium] = nil
    if not next(message._meta[KEY]) then
      message._meta[KEY] = nil
    end
  end
  -- Save immediately so closing/restarting before another request retains the choice.
  local history = require("maxa.session").history()
  if history and history.save_chat then
    history.save_chat(chat)
  end
  return true
end

-- Explicit/session/project selections precede the existing global resolver.
function M.resolve(req, medium, explicit)
  if explicit ~= nil and explicit ~= vim.NIL and not (type(explicit) == "string" and vim.trim(explicit) == "") then
    return explicit
  end
  local chat = req and req.caller and req.caller.maxa_ai and req.caller.maxa_ai.chat
  local selected = M.get(chat, medium)
  if selected then return selected end
  local root = chat and chat.opts and (chat.opts.project_root or chat.opts.cwd)
    or (req and req.caller and req.caller.hubui and req.caller.hubui.project_root)
    or (req and req.caller and req.caller.cwd)
  if root then return require("maxa.project.settings").media_adapter(root, medium) end
  return nil
end

return M
