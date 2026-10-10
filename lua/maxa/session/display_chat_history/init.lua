-- filepath: lua/maxa/session/display_chat_history/init.lua
-- Display Chat History Extension for Maxa AI
-- 保存和恢复 Display Chat 会话

local config = require("maxa.config")
local log = require("maxa.utils.log")

---@class DisplayChatHistory.Extension
local Extension = {}

---@class DisplayChatHistory.Config
local default_opts = {
  -- 保存路径
  save_dir = vim.fs.joinpath(vim.fn.stdpath("data"), "maxa-ai", "history"),
  -- 最大保存数量
  max_saved = 50,
  -- 自动保存间隔 (秒), 0 表示禁用
  auto_save_interval = 0,
  -- 保存时的最小消息数
  min_messages = 2,
  -- 快捷键
  keymap_save = "ghs",
  keymap_load = "ghl",
}

local opts = {}

---序列化 chat 数据用于保存
---@param chat MaxaAI.Chat
---@return table|nil
local function serialize_chat(chat)
  if not chat or not chat.messages or #chat.messages < opts.min_messages then
    return nil
  end

  -- 过滤掉不可序列化的字段
  local messages = {}
  for _, msg in ipairs(chat.messages) do
    table.insert(messages, {
      role = msg.role,
      content = msg.content,
      opts = msg.opts,
      -- 保留 context 信息但移除函数引用
      context = msg.context and {
        id = msg.context.id,
        path = msg.context.path,
      } or nil,
    })
  end

  return {
    id = chat.id,
    title = chat.title or ("Chat " .. chat.id),
    adapter_name = chat.adapter and chat.adapter.name or "unknown",
    adapter_type = chat.adapter and chat.adapter.type or "http",
    messages = messages,
    settings = chat.settings,
    created_at = os.time(),
    cycle = chat.cycle,
  }
end

---获取保存文件路径
---@param chat_id number
---@return string
local function get_save_path(chat_id)
  return string.format("%s/%d.json", opts.save_dir, chat_id)
end

---确保保存目录存在
local function ensure_save_dir()
  if vim.fn.isdirectory(opts.save_dir) == 0 then
    vim.fn.mkdir(opts.save_dir, "p")
  end
end

---保存单个 chat
---@param chat MaxaAI.Chat
---@return boolean success
local function save_chat(chat)
  local data = serialize_chat(chat)
  if not data then
    log:debug("[DisplayChatHistory] Chat has too few messages, skipping save")
    return false
  end

  ensure_save_dir()

  local path = get_save_path(data.id)
  local json = vim.fn.json_encode(data)

  local file = io.open(path, "w")
  if not file then
    log:error("[DisplayChatHistory] Failed to open file for writing: %s", path)
    return false
  end

  file:write(json)
  file:close()

  log:info("[DisplayChatHistory] Saved chat %d to %s", data.id, path)
  return true
end

---列出所有保存的 chat
---@return table[]
local function list_saved_chats()
  ensure_save_dir()

  local chats = {}
  local files = vim.fn.glob(opts.save_dir .. "/*.json", false, true)

  for _, file in ipairs(files) do
    local content = vim.fn.readfile(file)
    if content and #content > 0 then
      local ok, data = pcall(vim.json.decode, table.concat(content, "\n"), { luanil = { object = true, array = true } })
      if ok and data then
        table.insert(chats, {
          id = data.id,
          title = data.title,
          adapter_name = data.adapter_name,
          adapter_type = data.adapter_type,
          created_at = data.created_at,
          message_count = #data.messages,
          path = file,
        })
      end
    end
  end

  -- 按创建时间排序 (最新的在前)
  table.sort(chats, function(a, b)
    return (a.created_at or 0) > (b.created_at or 0)
  end)

  return chats
end

---加载保存的 chat
---@param path string
---@return table|nil
local function load_chat_data(path)
  local content = vim.fn.readfile(path)
  if not content or #content == 0 then
    return nil
  end

  local ok, data = pcall(vim.json.decode, table.concat(content, "\n"), { luanil = { object = true, array = true } })
  if not ok then
    log:error("[DisplayChatHistory] Failed to parse chat file: %s", path)
    return nil
  end

  return data
end

---恢复 chat 到新的 chat buffer
---@param data table
---@return MaxaAI.Chat|nil
local function restore_chat(data)
  local maxa_ai = require("maxa")

  -- 创建新的 chat，传入保存的消息
  local chat = maxa_ai.chat({
    messages = data.messages,
    auto_submit = false,
  })

  if chat then
    -- 恢复标题
    if data.title then
      chat:set_title(data.title .. " (restored)")
    end
    log:info("[DisplayChatHistory] Restored chat: %s", data.title)
  end

  return chat
end

---删除保存的 chat
---@param path string
---@return boolean
local function delete_saved_chat(path)
  local ok = os.remove(path)
  if ok then
    log:info("[DisplayChatHistory] Deleted: %s", path)
  end
  return ok ~= nil
end

---清理旧的保存文件，保留最新的 max_saved 个
local function cleanup_old_saves()
  local chats = list_saved_chats()
  if #chats <= opts.max_saved then
    return
  end

  for i = opts.max_saved + 1, #chats do
    delete_saved_chat(chats[i].path)
  end
end

---显示保存的 chat 列表供选择
local function show_chat_picker()
  local chats = list_saved_chats()

  if #chats == 0 then
    vim.notify("[DisplayChatHistory] No saved chats found", vim.log.levels.INFO)
    return
  end

  -- 使用 vim.ui.select 显示列表
  local items = {}
  for _, chat in ipairs(chats) do
    local date = chat.created_at and os.date("%Y-%m-%d %H:%M", chat.created_at) or "unknown"
    table.insert(items, {
      display = string.format("[%s] %s (%d msgs) - %s", chat.adapter_name, chat.title, chat.message_count, date),
      data = chat,
    })
  end

  vim.ui.select(items, {
    prompt = "Select chat to restore:",
    format_item = function(item)
      return item.display
    end,
  }, function(choice)
    if not choice then
      return
    end

    local data = load_chat_data(choice.data.path)
    if data then
      restore_chat(data)
    end
  end)
end

---Setup the extension
---@param user_opts table
function Extension.setup(user_opts)
  opts = vim.tbl_deep_extend("force", default_opts, user_opts or {})

  -- 添加 keymaps 到 chat buffer
  local chat_keymaps = config.interactions.chat.keymaps

  -- 保存当前 chat
  chat_keymaps.save_chat_history = {
    modes = { n = opts.keymap_save },
    description = "[History] Save current chat",
    callback = function(chat)
      if save_chat(chat) then
        -- vim.notify("[DisplayChatHistory] Chat saved!", vim.log.levels.INFO)
        cleanup_old_saves()
      else
        vim.notify("[DisplayChatHistory] Failed to save chat (too few messages?)", vim.log.levels.WARN)
      end
    end,
  }

  -- 加载保存的 chat
  chat_keymaps.load_chat_history = {
    modes = { n = opts.keymap_load },
    description = "[History] Load saved chat",
    callback = function(_chat)
      show_chat_picker()
    end,
  }

  -- 注册 chat 关闭时的自动保存 (可选)
  vim.api.nvim_create_autocmd("User", {
    pattern = "MaxaAIChatClosed",
    callback = function(args)
      if opts.auto_save_interval > 0 then
        -- 自动保存逻辑
        local chat = require("maxa").buf_get_chat(args.data and args.data.bufnr)
        if chat then
          save_chat(chat)
          cleanup_old_saves()
        end
      end
    end,
  })

  log:info("[DisplayChatHistory] Extension loaded")
end

-- 导出的函数
Extension.exports = {
  save = function(chat)
    return save_chat(chat)
  end,

  list = function()
    return list_saved_chats()
  end,

  load = function(path)
    local data = load_chat_data(path)
    if data then
      return restore_chat(data)
    end
    return nil
  end,

  delete = function(path)
    return delete_saved_chat(path)
  end,

  show_picker = function()
    show_chat_picker()
  end,

  cleanup = function()
    cleanup_old_saves()
  end,
}

return Extension
