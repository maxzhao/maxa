-- filepath: lua/maxa/mcphub/native_servers/subagent/tools/multi_agent/display_adapter.lua
-- DisplayAdapter: 自定义适配器，支持动态 formatted_name 实现多角色显示
-- 用于 Multi-Agent 协作系统的 Display Chat

---@class DisplayAdapter
---@field name string 适配器名称
---@field type string 类型
---@field formatted_name string 显示名称 (可动态修改)
---@field roles table 角色映射
---@field features table 功能特性
---@field opts table 额外选项
---@field url string API URL (必需但不调用)
---@field headers table 请求头
---@field parameters table 请求参数
---@field schema table 参数 schema
---@field handlers table 处理函数
local DisplayAdapter = {
  name = "multi_agent_display",
  formatted_name = "Agent",
  type = "http",
  roles = {
    llm = "assistant",
    user = "user",
  },
  features = {
    tokens = false,
    text = true,
  },
  opts = {
    stream = false,
    tools = false,
  },
  url = "http://localhost/noop",
  headers = {},
  parameters = {},
  -- schema 必须包含 model 字段，否则 Chat.new() 会报错
  -- 使用空字符串避免显示 "display-only"
  schema = {
    model = {
      default = "",
    },
  },
  handlers = {
    lifecycle = {
      ---@param self DisplayAdapter
      ---@return boolean
      setup = function(self)
        return true
      end,
    },
  },
}

--- 动态修改 formatted_name，影响 Chat 中的角色头显示
---@param agent_name string Agent 名称
---@param icon? string 图标 (默认: 🤖)
function DisplayAdapter:set_current_agent(agent_name, icon)
  self.formatted_name = (icon or "🤖") .. " " .. agent_name
end

--- 注入 Agent 消息到 Display Chat
---@param display_chat table Maxa AI Chat 实例
---@param agent_name string Agent 名称
---@param icon string|nil 图标
---@param round number 轮次
---@param message string 消息内容
---@param role_desc string|nil 角色描述（可选）
local function inject_message(display_chat, agent_name, icon, round, message, role_desc)
  -- 1. 设置当前 Agent（影响角色头显示）
  -- 如果有角色描述，显示为 "🤖 A (角色描述)"
  local display_name = agent_name
  if role_desc and role_desc ~= "" then
    display_name = agent_name .. " (" .. role_desc .. ")"
  end
  display_chat.adapter:set_current_agent(display_name, icon)

  -- 2. 构建格式化的消息内容（包含空行、Agent 标识和分隔线，用于 history 恢复时显示）
  -- 开头添加空行，使其与上一个分隔线之间有间距
  local formatted_content = string.format("\n## %s %s\n\n%s\n\n---\n", icon or "🤖", display_name, message)

  -- 3. 添加消息到 chat.messages（用于 history 保存）
  if display_chat.messages then
    table.insert(display_chat.messages, {
      role = "assistant",
      content = formatted_content,
    })
  end

  -- 4. 添加消息到 buffer（触发角色头渲染，包含分隔线）
  -- 开头添加空行，使其与上一个分隔线之间有间距
  display_chat:add_buf_message({
    role = "llm",
    content = "\n" .. message .. "\n\n---",
  }, {
    force_role = true, -- 强制显示角色头
  })

end

--- 注入"⏳ 思考中..."指示器到 Display Chat
--- Agent 开始执行时调用，handoff 完成后被 inject_message 的最终结果覆盖
---@param display_chat table Maxa AI Chat 实例
---@param agent_name string Agent 名称
---@param icon string|nil 图标
---@param role_desc string|nil 角色描述（可选）
local function inject_thinking(display_chat, agent_name, icon, role_desc)
  -- 设置当前 Agent（影响角色头显示）
  local display_name = agent_name
  if role_desc and role_desc ~= "" then
    display_name = agent_name .. " (" .. role_desc .. ")"
  end
  display_chat.adapter:set_current_agent(display_name, icon)

  -- ⭐ 清理 buffer 中 render 产生的 "## Me" header（仅在首次调用时需要）
  -- Chat.new 的 render 会添加 "## Me" header，但 DisplayChat 不需要
  if display_chat.bufnr and vim.api.nvim_buf_is_valid(display_chat.bufnr) then
    local bufnr = display_chat.bufnr
    if display_chat.ui then display_chat.ui:unlock_buf() end
    local total = vim.api.nvim_buf_line_count(bufnr)
    -- 找到并删除 "## Me" header 块
    local me_header_line = nil
    for i = 1, math.min(total, 5) do
      local line = vim.api.nvim_buf_get_lines(bufnr, i - 1, i, false)[1]
      if line and line:match("^## Me") then
        me_header_line = i
        break
      end
    end
    if me_header_line then
      -- 找到 header 块结束位置（空行 + context 行）
      local header_end = me_header_line
      for i = me_header_line + 1, total do
        local line = vim.api.nvim_buf_get_lines(bufnr, i - 1, i, false)[1]
        if line and (line == "" or line:match("^>%s") or line:match("^> Context")) then
          header_end = i
        else
          break
        end
      end
      vim.api.nvim_buf_set_lines(bufnr, me_header_line - 1, header_end, false, {})
      -- 清理 extmark headers
      local ns_header = vim.api.nvim_create_namespace("MaxaAI-headers")
      vim.api.nvim_buf_clear_namespace(bufnr, ns_header, 0, -1)
    end
    if display_chat.ui then display_chat.ui:lock_buf() end
  end

  -- 添加"⏳ 思考中..."到 buffer（触发角色头渲染）
  display_chat:add_buf_message({
    role = "llm",
    content = "\n⏳ 思考中...",
  }, {
    force_role = true,
  })

  -- 记录"思考中..."在 buffer 中的位置，用于后续替换
  -- 保存在 display_chat 的临时字段中
  if display_chat.bufnr and vim.api.nvim_buf_is_valid(display_chat.bufnr) then
    local line_count = vim.api.nvim_buf_line_count(display_chat.bufnr)
    -- 从末尾往前找"⏳"所在行
    local search_start = math.max(0, line_count - 5)
    local lines = vim.api.nvim_buf_get_lines(display_chat.bufnr, search_start, line_count, false)
    for i = #lines, 1, -1 do
      if lines[i]:match("⏳") then
        display_chat._thinking_line = search_start + i - 1 -- 0-based
        break
      end
    end

  end
end

--- 将"⏳ 思考中..."替换为最终 message
--- 如果有 thinking_line 记录，替换该行到 buffer 末尾的内容
---@param display_chat table Maxa AI Chat 实例
---@param message string 最终消息
local function replace_thinking(display_chat, message)
  if not display_chat._thinking_line then
    return false
  end

  local bufnr = display_chat.bufnr
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    display_chat._thinking_line = nil
    return false
  end

  local thinking_line = display_chat._thinking_line
  local line_count = vim.api.nvim_buf_line_count(bufnr)

  -- 验证该行确实是"思考中..."
  local lines = vim.api.nvim_buf_get_lines(bufnr, thinking_line, thinking_line + 1, false)
  if not lines[1] or not lines[1]:match("⏳") then
    display_chat._thinking_line = nil
    return false
  end

  -- unlock buffer
  if display_chat.ui then
    display_chat.ui:unlock_buf()
  end

  -- 构建替换内容
  local replacement_lines = {}
  for line in message:gmatch("([^\n]*)\n?") do
    table.insert(replacement_lines, line)
  end
  -- 移除末尾可能的空行
  while #replacement_lines > 0 and replacement_lines[#replacement_lines] == "" do
    table.remove(replacement_lines)
  end
  -- 添加分隔线
  table.insert(replacement_lines, "")
  table.insert(replacement_lines, "---")

  -- 替换 thinking_line 到 buffer 末尾的内容
  pcall(vim.api.nvim_buf_set_lines, bufnr, thinking_line, line_count, false, replacement_lines)

  -- lock buffer
  if display_chat.ui then
    display_chat.ui:lock_buf()
  end

  -- 移动光标到末尾
  if display_chat.ui then
    display_chat.ui:move_cursor(true)
  end

  display_chat._thinking_line = nil
  return true
end

--- 深拷贝辅助函数 (兼容非 Neovim 环境)
---@param orig table
---@return table
local function deepcopy(orig)
  if vim and vim.deepcopy then
    return vim.deepcopy(orig)
  end
  -- 简单深拷贝实现 (用于测试环境)
  local copy = {}
  for k, v in pairs(orig) do
    if type(v) == "table" then
      copy[k] = deepcopy(v)
    else
      copy[k] = v
    end
  end
  setmetatable(copy, getmetatable(orig))
  return copy
end

--- 创建 DisplayAdapter 的独立副本
---@return DisplayAdapter
local function create(adapter)
  -- Keep the resolved provider identity/metatable. This Chat only projects
  -- discussion messages; Phase 2 later installs a fresh execution adapter.
  local adapters = require("maxa.adapters")
  assert(adapters.resolved(adapter), "Display Chat requires a resolved provider adapter")
  local copy = deepcopy(adapter)
  copy.formatted_name = "Agent"
  copy.set_current_agent = DisplayAdapter.set_current_agent
  return copy
end

return {
  DisplayAdapter = DisplayAdapter,
  inject_message = inject_message,
  inject_thinking = inject_thinking,
  replace_thinking = replace_thinking,
  create = create,
}
