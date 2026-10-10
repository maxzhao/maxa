-- pick_session: 弹出 Snacks picker 选择历史会话，插入 save_id 到 chat buffer
--
-- 流程:
-- 1. 通过 history API 获取所有会话元数据
-- 2. 用 Snacks picker 展示（含预览）
-- 3. 用户选择后，在 chat buffer 用户编辑区插入 "save_id: xxx"

local compact_utils = require("maxa.session.slash_commands.compact_utils")

---@class MaxaAI.SlashCommand.PickSession: MaxaAI.SlashCommand
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

--- 格式化相对时间
---@param timestamp number
---@return string
local function format_relative_time(timestamp)
  local diff = os.time() - timestamp
  if diff < 60 then
    return diff .. "s"
  elseif diff < 3600 then
    return math.floor(diff / 60) .. "m"
  elseif diff < 86400 then
    return math.floor(diff / 3600) .. "h"
  else
    return math.floor(diff / 86400) .. "d"
  end
end

--- 将 index 数据转为排序后的 items 列表
---@param chats_data table<string, table> index 数据
---@return table[] items
local function format_items(chats_data)
  local items = {}
  for save_id, info in pairs(chats_data) do
    table.insert(items, vim.tbl_extend("keep", {
      save_id = save_id,
      title = info.title or save_id,
      updated_at = info.updated_at or 0,
    }, info))
  end
  table.sort(items, function(a, b)
    return a.updated_at > b.updated_at
  end)
  return items
end

--- 格式化单条 item 的显示文本
---@param item table
---@param current_save_id string|nil 当前会话 ID
---@return string
local function format_entry(item, current_save_id)
  local parts = {}

  -- 当前会话标记
  local is_current = current_save_id and item.save_id == current_save_id
  table.insert(parts, is_current and "" or " ")

  -- 标题
  table.insert(parts, item.title or "Untitled")

  -- Token 估算
  if item.token_estimate and item.token_estimate > 0 then
    table.insert(parts, string.format("(~%.1fk)", item.token_estimate / 1000))
  end

  -- 相对时间
  if item.updated_at and item.updated_at > 0 then
    table.insert(parts, " " .. format_relative_time(item.updated_at))
  end

  return table.concat(parts, " ")
end

--- 生成预览行（简化版，不依赖 UI 类）
---@param chat_data table 完整的 chat 数据
---@return string[] lines
local function get_preview_lines(chat_data)
  local config = require("maxa.config")
  local lines = {}

  -- adapter / model 信息
  if chat_data.adapter or (chat_data.settings and chat_data.settings.model) then
    table.insert(lines, "---")
    if chat_data.adapter then
      table.insert(lines, string.format("adapter: %s", tostring(chat_data.adapter)))
    end
    if chat_data.settings and chat_data.settings.model then
      table.insert(lines, string.format("model: %s", tostring(chat_data.settings.model)))
    end
    table.insert(lines, "---")
    table.insert(lines, "")
  end

  -- 消息内容
  local system_role = config.constants.SYSTEM_ROLE
  local user_role = config.constants.USER_ROLE
  local llm_role = config.constants.LLM_ROLE
  local last_set_role = nil

  for _, msg in ipairs(chat_data.messages or {}) do
    if msg.role ~= system_role and not (msg.opts and msg.opts.visible == false) then
      if msg.role == user_role and last_set_role ~= user_role then
        if last_set_role then
          table.insert(lines, "")
        end
        table.insert(lines, "## User")
        table.insert(lines, "")
      elseif msg.role == llm_role and last_set_role ~= llm_role then
        if last_set_role then
          table.insert(lines, "")
        end
        table.insert(lines, "## Assistant")
        table.insert(lines, "")
      end

      local content = msg.content or ""
      if type(content) == "table" then
        content = type(content.content) == "string" and content.content or "[Message Cannot Be Displayed]"
      end
      for _, line in ipairs(vim.split(content, "\n", { plain = true })) do
        table.insert(lines, line)
      end

      last_set_role = msg.role
    end
  end

  return lines
end

--- 用 Snacks picker 展示会话列表
---@param chat table 当前 Chat 实例
---@param items table[] 排序后的 items
---@param history_api table history 导出的 API
local function open_picker(chat, context, items, history_api)
  local current_save_id = chat.opts and chat.opts.save_id
  local insertion = require("maxa.interactions.chat.slash_commands.insertion")
  local confirmed = false

  require("snacks.picker").pick({
    title = "Pick Session",
    items = items,
    main = { file = false, float = true },
    format = function(item)
      return { { format_entry(item, current_save_id) } }
    end,
    transform = function(item)
      item.file = item.save_id
      item.text = item.title or item.save_id
      return item
    end,
    preview = function(ctx)
      local item = ctx.item
      local full_chat = history_api.load_chat(item.save_id)
      if not full_chat then
        local buf_id = ctx.preview:scratch()
        vim.api.nvim_buf_set_lines(buf_id, 0, -1, false, { "Chat data not available" })
        return
      end

      local preview_lines = get_preview_lines(full_chat)
      local buf_id = ctx.preview:scratch()
      vim.bo[buf_id].filetype = "markdown"
      vim.api.nvim_buf_set_lines(buf_id, 0, -1, false, preview_lines)
    end,
    on_close = function()
      if not confirmed then insertion.discard_anchor(chat, context) end
    end,
    confirm = function(picker, _)
      local selections = picker:selected({ fallback = true })
      if not selections or #selections == 0 then
        return
      end
      confirmed = true
      picker:close()

      local selected = selections[1]
      local text = "save_id: " .. selected.save_id
      insertion.add(chat, context, { content = text })
    end,
  })
end

--- 执行 slash command
---@param SlashCommands MaxaAI.SlashCommands
---@return nil
function SlashCommand:execute(SlashCommands)
  local history_api = compact_utils.get_history_api()
  if not history_api then
    vim.notify("[pick_session] History extension not available", vim.log.levels.ERROR)
    return
  end

  local chats_data = history_api.get_chats()
  if not chats_data or vim.tbl_isempty(chats_data) then
    vim.notify("[pick_session] No saved chats found", vim.log.levels.INFO)
    return
  end

  local items = format_items(chats_data)
  require("maxa.interactions.chat.slash_commands.insertion").track_context(self.Chat, self.context)
  open_picker(self.Chat, self.context, items, history_api)
end

return SlashCommand
