-- session history core/path/message utilities
-- Core path/save_id/history JSON helpers.

local history_utils = require("maxa.session.history.utils")

local M = {}

-- 版本信息
M.VERSION = "0.0.2"

-- 获取历史记录存储目录
-- 逻辑与 history_storage.lua 的 setup_storage_dir_hook 保持一致
function M.get_history_dir()
  -- 使用 vim.fs.root 检测项目根目录（只检测 .maxa）
  local project_root = vim.fs.root(0, { ".maxa" })

  if project_root then
    local taskmaster_dir = project_root .. "/.maxa"
    -- 检查 .maxa 目录是否存在
    if vim.fn.isdirectory(taskmaster_dir) == 1 then
      local project_history_dir = taskmaster_dir .. "/history"
      return project_history_dir
    end
  end

  -- 回退到全局存储目录
  return vim.fs.joinpath(vim.fn.stdpath("data"), "maxa-ai", "history")
end

---Generate a collision-resistant save_id for session-created sessions.
---@param opts? table
---@return string
function M.generate_save_id(opts)
  opts = opts or {}
  if not opts.history_dir then
    opts.history_dir = M.get_history_dir()
  end
  return history_utils.generate_save_id(opts)
end

local UNSAVABLE_SAVE_ID_PREFIX = "_session_unsavable_"

---Create a controlled invalid save_id that Maxa AI history will not persist.
---
---The history storage validator rejects save_ids containing `/` or `\\` to
---prevent path traversal. Maxa uses that existing validation path as a
---shared primitive for temporary interactive chats (rescue/scratch/merge
---workspaces) that must run normally but never appear in history.
---@param kind? string short namespace, e.g. "scratch" or "rescue"
---@return string
function M.make_unsavable_save_id(kind)
  kind = tostring(kind or "temp")
  kind = kind:gsub("[^%w_-]", "_")
  local suffix = history_utils.generate_save_id({ prefix = kind })
  return UNSAVABLE_SAVE_ID_PREFIX .. kind .. "/" .. suffix
end

---Return whether a save_id is one of Maxa's controlled non-persistent IDs.
---@param save_id any
---@param kind? string optional namespace to match
---@return boolean
function M.is_unsavable_save_id(save_id, kind)
  if type(save_id) ~= "string" then
    return false
  end
  local prefix = UNSAVABLE_SAVE_ID_PREFIX
  if kind ~= nil then
    kind = tostring(kind):gsub("[^%w_-]", "_")
    prefix = prefix .. kind .. "/"
  end
  return vim.startswith(save_id, prefix) and save_id:match("[/\\]") ~= nil
end

-- 获取索引文件路径
function M.get_index_path()
  return M.get_history_dir() .. "/index.json"
end

-- 获取会话文件路径
function M.get_chat_path(save_id)
  return M.get_history_dir() .. "/chats/" .. save_id .. ".json"
end

-- 读取 JSON 文件
function M.read_json_file(path)
  if vim.fn.filereadable(path) == 0 then
    return nil, "File not found: " .. path
  end

  local lines = vim.fn.readfile(path)
  local content = table.concat(lines, "\n")

  local ok, data = pcall(vim.json.decode, content)
  if not ok then
    return nil, "Failed to parse JSON: " .. tostring(data)
  end

  return data, nil
end

-- 读取索引文件
function M.read_index()
  local index_path = M.get_index_path()
  return M.read_json_file(index_path)
end

-- 读取会话文件
function M.read_chat(save_id)
  local chat_path = M.get_chat_path(save_id)
  return M.read_json_file(chat_path)
end

-- 创建版本信息
function M.create_version_info()
  return {
    version = M.VERSION,
    name = "session",
  }
end

-- 创建标准响应结构
function M.create_response(data)
  return {
    data = data,
    version = M.create_version_info(),
  }
end

--- 检查消息是否匹配 pattern (Lua pattern)
---@param msg table 消息对象
---@param pattern string Lua pattern
---@return boolean
local function msg_matches_pattern(msg, pattern)
  -- conversation: user/llm 无 tools，匹配 content
  if (msg.role == "user" or msg.role == "llm") and not msg.tools then
    return msg.content and msg.content:match(pattern) ~= nil
  end

  -- tool response: 匹配 content (包含工具名和输出)
  if msg.role == "tool" then
    return msg.content and msg.content:match(pattern) ~= nil
  end

  -- tool request: 匹配 function.name 和 function.arguments
  if msg.role == "llm" and msg.tools and msg.tools.calls then
    for _, call in ipairs(msg.tools.calls) do
      local func = call["function"]
      if func then
        -- 匹配工具名
        if func.name and func.name:match(pattern) then
          return true
        end
        -- 匹配入参
        if func.arguments and func.arguments:match(pattern) then
          return true
        end
      end
    end
  end

  return false
end

-- 过滤消息类型
-- @param messages 消息列表
-- @param opts 过滤选项表或字符串(向后兼容)
--   opts.type: "all" | "conversation" | "tool_calls" | "tool_requests" | "tool_responses" | "tool_errors"
--   opts.pattern: string | nil (Lua pattern 匹配)
function M.filter_messages(messages, opts)
  -- 向后兼容: 支持直接传字符串
  if type(opts) == "string" then
    opts = { type = opts }
  end
  opts = opts or {}

  local msg_type = opts.type or "all"
  local pattern = opts.pattern

  if not messages then
    return {}
  end

  -- 无过滤条件时返回全部（但需要包装成统一格式）
  if msg_type == "all" and not pattern then
    local result = {}
    for i, msg in ipairs(messages) do
      table.insert(result, { _original_index = i, msg = msg })
    end
    return result
  end

  local filtered = {}

  for i, msg in ipairs(messages) do
    local include = false

    if msg_type == "conversation" then
      -- 只包含对话消息 (user 无 context + llm 无 tools.calls)
      if msg.role == "user" and not msg.context then
        include = true
      elseif msg.role == "llm" and not (msg.tools and msg.tools.calls) then
        include = true
      end
    elseif msg_type == "tool_calls" then
      -- 只包含工具调用相关消息 (request + response)
      if msg.tools or msg.role == "tool" then
        include = true
      end
    elseif msg_type == "tool_requests" then
      -- 仅 llm 发起的工具调用请求
      if msg.role == "llm" and msg.tools and msg.tools.calls then
        include = true
      end
    elseif msg_type == "tool_responses" then
      -- 仅工具执行结果
      if msg.role == "tool" then
        include = true
      end
    elseif msg_type == "tool_errors" then
      -- 只包含工具错误消息
      if msg.role == "tool" and M.is_tool_error(msg) then
        include = true
      end
    elseif msg_type == "user_only" then
      -- 只包含用户消息 (无 context)
      if msg.role == "user" and not msg.context then
        include = true
      end
    elseif msg_type == "llm_only" then
      -- 只包含 LLM 对话消息 (无 tool calls)
      if msg.role == "llm" and not (msg.tools and msg.tools.calls) then
        include = true
      end
    elseif msg_type == "system_only" then
      -- 只包含系统消息
      if msg.role == "system" then
        include = true
      end
    elseif msg_type == "context_only" then
      -- 只包含上下文消息 (有 context 属性)
      if msg.context then
        include = true
      end
    else
      -- msg_type == "all"
      include = true
    end

    -- 应用 pattern 匹配
    if include and pattern then
      include = msg_matches_pattern(msg, pattern)
    end

    if include then
      -- 保留原始索引
      table.insert(filtered, { _original_index = i, msg = msg })
    end
  end

  return filtered
end

-- 统计消息类型
function M.count_message_types(messages)
  local counts = {
    total = 0,
    user = 0,
    llm = 0,
    system = 0,
    tool = 0,
    tool_calls = 0,
    tool_errors = 0,
  }

  if not messages then
    return counts
  end

  for _, msg in ipairs(messages) do
    counts.total = counts.total + 1

    if msg.role == "user" then
      counts.user = counts.user + 1
    elseif msg.role == "llm" then
      counts.llm = counts.llm + 1
      -- 检查是否有工具调用
      if msg.tools and msg.tools.calls then
        counts.tool_calls = counts.tool_calls + #msg.tools.calls
      end
    elseif msg.role == "system" then
      counts.system = counts.system + 1
    elseif msg.role == "tool" then
      counts.tool = counts.tool + 1
      -- 检查是否是错误（通过内容检测）
      if M.is_tool_error(msg) then
        counts.tool_errors = counts.tool_errors + 1
      end
    end
  end

  return counts
end

-- 格式化时间戳 (save_id 格式: 20250129_123456)
function M.format_save_id_time(save_id)
  if not save_id or #save_id < 15 then
    return save_id
  end

  local year = save_id:sub(1, 4)
  local month = save_id:sub(5, 6)
  local day = save_id:sub(7, 8)
  local hour = save_id:sub(10, 11)
  local min = save_id:sub(12, 13)
  local sec = save_id:sub(14, 15)

  return string.format("%s-%s-%s %s:%s:%s", year, month, day, hour, min, sec)
end

-- 截断内容（用于摘要）
function M.truncate_content(content, max_length)
  max_length = max_length or 200

  if not content or #content <= max_length then
    return content
  end

  return content:sub(1, max_length) .. "..."
end

-- 检查工具响应是否为错误
-- MaxaAI 的工具错误格式: "**`tool_name` Tool**: Failed with the following error:"
-- 成功格式: "**`tool_name` Tool**: Returned the following:"
---@param msg table 消息对象 (role == "tool")
---@return boolean
function M.is_tool_error(msg)
  if msg.role ~= "tool" then
    return false
  end

  -- 优先检查 is_error 字段（如果 MaxaAI 未来支持）
  if msg.tools and msg.tools.is_error then
    return true
  end

  -- 通过 content 内容检测错误
  if msg.content and type(msg.content) == "string" then
    -- 匹配 "**`xxx` Tool**: Failed with the following error:"
    if msg.content:match("^%*%*`[^`]+` Tool%*%*: Failed") then
      return true
    end
  end

  return false
end

-- 获取会话的第一条用户消息（作为标题）
function M.get_chat_title(messages)
  if not messages then
    return "Untitled"
  end

  for _, msg in ipairs(messages) do
    if msg.role == "user" and msg.content then
      local title = msg.content:gsub("\n", " "):gsub("%s+", " ")
      return M.truncate_content(title, 100)
    end
  end

  return "Untitled"
end

return M
