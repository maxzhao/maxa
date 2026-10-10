-- Shared helpers for handoff commands and explicit range/history tools.

local compaction_messages = require("maxa.session.compaction_messages")
local M = {}

local function result_call_id(call)
  return call and (call.call_id or call.id) or nil
end

-- ============================================================
-- 常量
-- ============================================================

M.CONSTANTS = { TOOL_CONTENT_MAX_LEN = 500 }

M.COMPACT_RANGE_ERROR_TYPES = {
  RANGES_REQUIRED = "ranges_required",
  INVALID_ACTION = "invalid_action",
  INVALID_INDEX = "invalid_index",
  RANGE_OVERLAP_AFTER_NORMALIZATION = "range_overlap_after_normalization",
  PROTECTED_PREFIX_OVERLAP = "protected_prefix_overlap",
  NO_CONVERSATION_CONTENT = "no_conversation_content",
  SUMMARY_GENERATION_FAILED = "summary_generation_failed",
  SAVE_ID_MISMATCH = "save_id_mismatch",
  SOURCE_ERROR = "source_error",
  APPLY_ERROR = "apply_error",
  UNKNOWN = "unknown",
}

local RETRYABLE_COMPACT_RANGE_ERROR_TYPES = {
  [M.COMPACT_RANGE_ERROR_TYPES.RANGES_REQUIRED] = true,
  [M.COMPACT_RANGE_ERROR_TYPES.INVALID_ACTION] = true,
  [M.COMPACT_RANGE_ERROR_TYPES.INVALID_INDEX] = true,
  [M.COMPACT_RANGE_ERROR_TYPES.RANGE_OVERLAP_AFTER_NORMALIZATION] = true,
  [M.COMPACT_RANGE_ERROR_TYPES.PROTECTED_PREFIX_OVERLAP] = true,
  [M.COMPACT_RANGE_ERROR_TYPES.NO_CONVERSATION_CONTENT] = true,
  [M.COMPACT_RANGE_ERROR_TYPES.SUMMARY_GENERATION_FAILED] = true,
}

function M.is_retryable_compact_range_error_type(error_type)
  return error_type ~= nil and RETRYABLE_COMPACT_RANGE_ERROR_TYPES[error_type] == true
end

-- ============================================================
-- 公共函数
-- ============================================================

--- 从当前 chat 编辑区提取执行 slash command 前用户输入的压缩要求
---
--- 该内容不会进入主会话消息栈，只会作为本次压缩的高优先级补充规则注入
--- 到压缩执行子代理。优先复用 MaxaAI 的 parser.messages，以保持与
--- 正常提交消息一致的 Context/变量剥离行为。
---@param chat table|nil Maxa AI chat 实例
---@param context table|nil slash command completion context
---@param command_name string|nil 当前 slash command 名称（如 compact_silent）
---@return string|nil instructions 格式化后的压缩指示
function M.extract_slash_command_instructions(chat, context, command_name)
  local content = type(context) == "table" and context.pre_slash_command_input or nil

  if content and vim.trim(content) ~= "" then
    -- Snapshot captured by the canonical completion provider before
    -- the completion provider erased the slash-command trigger text.
  elseif not chat or not chat.bufnr or not vim.api.nvim_buf_is_valid(chat.bufnr) then
    return nil
  else
    local ok_parser, parser = pcall(require, "maxa.interactions.chat.parser")
    if ok_parser and chat.header_line and chat.chat_parser then
      local ok_msg, message = pcall(parser.messages, chat, chat.header_line)
      if ok_msg and message and type(message.content) == "string" then
        content = message.content
      end
    end

    if not content or vim.trim(content) == "" then
      local cursor = context and context.cursor
      local end_line = cursor and cursor.row or vim.api.nvim_buf_line_count(chat.bufnr)
      local start_line = math.max(1, tonumber(chat.header_line) or 1)
      if end_line >= start_line then
        local ok_lines, lines = pcall(vim.api.nvim_buf_get_lines, chat.bufnr, start_line - 1, end_line, false)
        if ok_lines and lines and #lines > 0 then
          content = table.concat(lines, "\n")
        end
      end
    end
  end

  content = vim.trim(content or "")
  if content == "" then
    return nil
  end

  -- Defensive trimming: if a provider accidentally captured more than the editable area,
  -- keep only the text after the last user header. This prevents historical transcript
  -- (## MaxaAI / tool summaries / previous answers) from becoming instructions.
  do
    local last_user_header_start = content:sub(1, 5) == "## Me" and 1 or nil
    local search_from = 1
    while true do
      local s = content:find("\n## Me", search_from, true)
      if not s then
        break
      end
      last_user_header_start = s + 1
      search_from = s + 1
    end
    if last_user_header_start then
      local tail = content:sub(last_user_header_start)
      tail = tail:gsub("^## Me[^\n]*\n?", "")
      local assistant_start = tail:find("\n## MaxaAI", 1, true)
      if assistant_start then
        tail = tail:sub(1, assistant_start - 1)
      end
      content = vim.trim(tail)
    end
  end

  local commands = { command_name, "compact_silent", "compact_rescue" }
  for _, name in ipairs(commands) do
    if name and name ~= "" then
      local escaped = vim.pesc("/" .. name)
      -- 常见形态：单独一行 slash command，或位于输入末尾的触发 token。
      content = content:gsub("\n%s*" .. escaped .. "%s*$", "")
      content = content:gsub("^%s*" .. escaped .. "%s*$", "")
      content = content:gsub("%s+" .. escaped .. "%s*$", "")
    end
  end
  -- Completion aliases/prefixes such as /comre may remain in the editable area.
  -- After known-command cleanup, remove any trailing slash token as command trigger.
  content = content:gsub("\n%s*/[%w_%-]+%s*$", "")
  content = content:gsub("%s+/[%w_%-]+%s*$", "")
  content = content:gsub("^%s*/[%w_%-]+%s*$", "")

  content = vim.trim(content)
  if content == "" then
    return nil
  end

  return content
end

--- 在 max_len 位置或之前找到最后一个完整 UTF-8 字符的末尾位置
--- 防止按字节截断时切断多字节字符（中文 3 字节、emoji 4 字节）
---@param s string 字符串
---@param max_len number 最大字节位置
---@return number safe_pos 安全截断位置（包含该字节）
local function utf8_safe_pos(s, max_len)
  if max_len >= #s then
    return #s
  end
  if max_len <= 0 then
    return 0
  end

  local pos = max_len
  local byte = s:byte(pos)

  -- 如果 pos 指向 continuation byte (10xxxxxx, 0x80-0xBF)，回退到 leading byte
  while pos > 0 and byte >= 0x80 and byte < 0xC0 do
    pos = pos - 1
    byte = pos > 0 and s:byte(pos) or 0
  end

  if pos <= 0 then
    return 0
  end

  -- 现在 pos 指向 leading byte 或 ASCII，计算该字符的总字节数
  local char_len
  if byte < 0x80 then
    char_len = 1
  elseif byte < 0xE0 then
    char_len = 2
  elseif byte < 0xF0 then
    char_len = 3
  else
    char_len = 4
  end

  -- 完整字符是否在 max_len 范围内
  if pos + char_len - 1 <= max_len then
    return pos + char_len - 1 -- 完整字符，包含它
  else
    return pos - 1 -- 字符不完整，退到上一个字符末尾
  end
end

--- 截断工具返回内容（UTF-8 安全）
---@param content string 原始内容
---@param max_len number 最大长度
---@return string 截断后的内容
function M.truncate_tool_content(content, max_len)
  if not content or #content <= max_len then
    return content
  end
  local safe_end = utf8_safe_pos(content, max_len)
  return content:sub(1, safe_end) .. "\n...[已截断, 省略 " .. (#content - safe_end) .. " 字符]..."
end

--- 检查消息是否为图片消息
---@param msg table 消息对象
---@return boolean
function M.is_image_message(msg)
  return (msg._meta and msg._meta.tag == "image") or false
end

--- 图片消息占位符
M.IMAGE_PLACEHOLDER = "[用户分享了一张图片]"

--- 深拷贝消息并截断非保留消息的内容
--- 图片消息的 base64 内容替换为占位符（避免巨量 token 浪费）
---@param messages table[] 原始消息列表
---@param max_len number|nil 最大截断长度（默认 TOOL_CONTENT_MAX_LEN）
---@return table[] 处理后的消息列表
function M.clone_messages_with_truncation(messages, max_len)
  local result = {}
  max_len = max_len or M.CONSTANTS.TOOL_CONTENT_MAX_LEN

  -- 第一遍：收集 OK_TOOL_CALLS 的 call IDs，用于决定哪些消息不截断
  local preserved_call_ids = {}
  for _, msg in ipairs(messages or {}) do
    if (msg.role == "llm" or msg.role == "assistant") and msg.tools and msg.tools.calls then
      for _, call in ipairs(msg.tools.calls) do
        local fn_name = call["function"] and call["function"].name
        if fn_name then
          for _, ok_tool in ipairs(compaction_messages.OK_TOOL_CALLS) do
            local call_id = result_call_id(call)
            if fn_name == ok_tool and call_id then
              preserved_call_ids[call_id] = true
            end
          end
        end
      end
    end
  end

  -- 第二遍：克隆消息，对非保留消息进行截断
  for _, msg in ipairs(messages or {}) do
    -- 图片消息：替换 base64 为占位符（避免巨量 token 浪费）
    if M.is_image_message(msg) then
      local cloned = vim.deepcopy(msg)
      cloned.content = M.IMAGE_PLACEHOLDER
      table.insert(result, cloned)
      goto continue
    end

    local cloned = vim.deepcopy(msg)
    local should_truncate = true

    if cloned.role == "system" or cloned.role == "user" then
      should_truncate = false
    elseif (cloned.role == "llm" or cloned.role == "assistant") then
      if cloned.tools and cloned.tools.calls then
        for _, call in ipairs(cloned.tools.calls) do
          local call_id = result_call_id(call)
          if call_id and preserved_call_ids[call_id] then
            should_truncate = false
            break
          end
        end
      end
    elseif cloned.role == "tool" then
      local call_id = (cloned.tools and cloned.tools.call_id) or cloned.tool_call_id
      if call_id and preserved_call_ids[call_id] then
        should_truncate = false
      end
    end

    if should_truncate then
      if cloned.role == "tool" and cloned.content then
        cloned.content = M.truncate_tool_content(cloned.content, max_len)
      end
    end

    table.insert(result, cloned)
    ::continue::
  end

  return result
end

--- 获取 history API
---@return table|nil api history extension API
function M.get_history_api()
  local ok, session = pcall(require, "maxa.session")
  return ok and session.history() or nil
end

return M
