-- filepath: lua/maxa/mcphub/native_servers/subagent/tools/multi_agent/session_manager.lua
-- SessionManager: 管理 Multi-Agent 会话的持久化
-- 基于 save_id + session 的简化方案

local log = require("maxa.utils.log")
local history_utils = require("maxa.session.history.utils")

---@class SessionManager
local M = {}

-- 版本信息
M.VERSION = "0.0.1"

--- 获取存储目录
---@return string 存储目录路径
function M.get_storage_dir()
  return vim.fn.expand("~/.local/share/nvim/maxa_ai/multi_agent")
end

--- 确保存储目录存在
---@return boolean success
function M.ensure_storage_dir()
  local dir = M.get_storage_dir()
  if vim.fn.isdirectory(dir) == 0 then
    local ok = vim.fn.mkdir(dir, "p")
    if ok == 0 then
      log:error("[SessionManager] Failed to create storage directory: %s", dir)
      return false
    end
  end
  return true
end

--- 生成唯一的 session ID
---@return string session_id 格式: ma_YYYYMMDD_HHMMSS_...
function M.generate_session_id()
  for _ = 1, 32 do
    local session_id = history_utils.generate_save_id({ prefix = "ma" })
    if vim.fn.filereadable(M.get_session_path(session_id)) == 0 then
      return session_id
    end
  end
  return history_utils.generate_save_id({ prefix = "ma" })
end

--- 获取会话文件路径
---@param session_id string 会话 ID
---@return string 文件路径
function M.get_session_path(session_id)
  return M.get_storage_dir() .. "/" .. session_id .. ".json"
end

--- 读取 JSON 文件
---@param path string 文件路径
---@return table|nil data 解析后的数据
---@return string|nil error 错误信息
local function read_json_file(path)
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

--- 写入 JSON 文件
---@param path string 文件路径
---@param data table 要写入的数据
---@return boolean success
---@return string|nil error 错误信息
local function write_json_file(path, data)
  local ok, json = pcall(vim.json.encode, data)
  if not ok then
    return false, "Failed to encode JSON: " .. tostring(json)
  end

  -- 格式化 JSON（添加缩进）
  -- 简单的格式化：每个顶级键换行
  local formatted = json

  local write_ok = pcall(vim.fn.writefile, { formatted }, path)
  if not write_ok then
    return false, "Failed to write file: " .. path
  end

  return true, nil
end

--- 保存会话元数据
---@param session table 会话数据
---@return boolean success
---@return string|nil error 错误信息
function M.save(session)
  if not session or not session.id then
    return false, "Invalid session: missing id"
  end

  -- 确保目录存在
  if not M.ensure_storage_dir() then
    return false, "Failed to create storage directory"
  end

  -- 更新时间戳
  session.updated_at = os.date("!%Y-%m-%dT%H:%M:%SZ")
  if not session.created_at then
    session.created_at = session.updated_at
  end

  -- 写入文件
  local path = M.get_session_path(session.id)
  local ok, err = write_json_file(path, session)
  if not ok then
    log:error("[SessionManager] Failed to save session %s: %s", session.id, err)
    return false, err
  end

  log:debug("[SessionManager] Saved session: %s", session.id)
  return true, nil
end

--- 加载会话元数据
---@param session_id string 会话 ID
---@return table|nil session 会话数据
---@return string|nil error 错误信息
function M.load(session_id)
  if not session_id or session_id == "" then
    return nil, "Invalid session_id"
  end

  local path = M.get_session_path(session_id)
  local data, err = read_json_file(path)
  if not data then
    log:debug("[SessionManager] Failed to load session %s: %s", session_id, err)
    return nil, err
  end

  log:debug("[SessionManager] Loaded session: %s", session_id)
  return data, nil
end

--- 检查会话是否存在
---@param session_id string 会话 ID
---@return boolean exists
function M.exists(session_id)
  if not session_id or session_id == "" then
    return false
  end
  local path = M.get_session_path(session_id)
  return vim.fn.filereadable(path) == 1
end

--- 列出所有会话
---@return table[] sessions 会话列表 [{id, created_at, updated_at, is_finished, agent_count, round}]
function M.list()
  local dir = M.get_storage_dir()
  if vim.fn.isdirectory(dir) == 0 then
    return {}
  end

  local files = vim.fn.glob(dir .. "/ma_*.json", false, true)
  local sessions = {}

  for _, file in ipairs(files) do
    local data, _ = read_json_file(file)
    if data and data.id then
      table.insert(sessions, {
        id = data.id,
        created_at = data.created_at,
        updated_at = data.updated_at,
        is_finished = data.state and data.state.is_finished or false,
        agent_count = data.config and data.config.agents and #data.config.agents or 0,
        round = data.state and data.state.round or 0,
        current_agent = data.state and data.state.current_agent or nil,
      })
    end
  end

  -- 按更新时间倒序排列
  table.sort(sessions, function(a, b)
    return (a.updated_at or "") > (b.updated_at or "")
  end)

  return sessions
end

--- 删除会话
---@param session_id string 会话 ID
---@return boolean success
---@return string|nil error 错误信息
function M.delete(session_id)
  if not session_id or session_id == "" then
    return false, "Invalid session_id"
  end

  local path = M.get_session_path(session_id)
  if vim.fn.filereadable(path) == 0 then
    return false, "Session not found: " .. session_id
  end

  local ok = vim.fn.delete(path)
  if ok ~= 0 then
    log:error("[SessionManager] Failed to delete session: %s", session_id)
    return false, "Failed to delete file"
  end

  log:debug("[SessionManager] Deleted session: %s", session_id)
  return true, nil
end

--- 创建新会话元数据结构
---@param config table 配置 {agents, termination}
---@return table session 会话元数据
function M.create_session(config)
  local session_id = M.generate_session_id()
  local now = os.date("!%Y-%m-%dT%H:%M:%SZ")

  return {
    id = session_id,
    created_at = now,
    updated_at = now,

    -- 配置（锁定，不可修改）
    config = {
      agents = vim.deepcopy(config.agents or {}),
      termination = vim.deepcopy(config.termination or {}),
      shared_background = vim.deepcopy(config.shared_background or {}),
      task = config.task,
      final_agent = config.final_agent,
      final_prompt = config.final_prompt,
      final_max_turns = config.final_max_turns,
      final_agent_config = vim.deepcopy(config.final_agent_config),
      title = config.title,
    },

    -- 状态
    state = {
      current_agent = nil,
      round = 0,
      is_finished = false,
    },

    -- Agent save_id 映射
    agent_save_ids = {},

    -- Display Chat save_id
    display_save_id = nil,

    -- 讨论历史
    discussions = {},
  }
end

--- 更新会话状态
---@param session table 会话数据
---@param state table 新状态 {current_agent?, round?, is_finished?}
---@return table session 更新后的会话
function M.update_state(session, state)
  if not session.state then
    session.state = {}
  end

  if state.current_agent ~= nil then
    session.state.current_agent = state.current_agent
  end
  if state.round ~= nil then
    session.state.round = state.round
  end
  if state.is_finished ~= nil then
    session.state.is_finished = state.is_finished
  end

  session.updated_at = os.date("!%Y-%m-%dT%H:%M:%SZ")
  return session
end

--- 添加 Agent save_id 映射
---@param session table 会话数据
---@param agent_name string Agent 名称
---@param save_id string save_id
---@return table session 更新后的会话
function M.add_agent_save_id(session, agent_name, save_id)
  if not session.agent_save_ids then
    session.agent_save_ids = {}
  end
  session.agent_save_ids[agent_name] = save_id
  session.updated_at = os.date("!%Y-%m-%dT%H:%M:%SZ")
  return session
end

--- 添加讨论记录
---@param session table 会话数据
---@param entry table {agent, round, message, timestamp?}
---@return table session 更新后的会话
function M.add_discussion(session, entry)
  if not session.discussions then
    session.discussions = {}
  end

  -- 添加时间戳
  if not entry.timestamp then
    entry.timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ")
  end

  table.insert(session.discussions, entry)
  session.updated_at = os.date("!%Y-%m-%dT%H:%M:%SZ")
  return session
end

--- 清理旧会话文件
--- 删除超过指定天数的已完成会话
---@param opts? table 选项 {max_age_days?: number, keep_unfinished?: boolean, dry_run?: boolean}
---@return table result {deleted: string[], kept: string[], errors: string[]}
function M.cleanup(opts)
  opts = opts or {}
  local max_age_days = opts.max_age_days or 7 -- 默认保留 7 天
  local keep_unfinished = opts.keep_unfinished ~= false -- 默认保留未完成的
  local dry_run = opts.dry_run or false

  local result = {
    deleted = {},
    kept = {},
    errors = {},
  }

  local dir = M.get_storage_dir()
  if vim.fn.isdirectory(dir) == 0 then
    return result
  end

  local files = vim.fn.glob(dir .. "/ma_*.json", false, true)
  local now = os.time()
  local max_age_seconds = max_age_days * 24 * 60 * 60

  for _, file in ipairs(files) do
    local data, err = read_json_file(file)
    if not data then
      table.insert(result.errors, file .. ": " .. (err or "unknown error"))
    else
      local should_delete = false
      local reason = ""

      -- 检查是否已完成
      local is_finished = data.state and data.state.is_finished

      if keep_unfinished and not is_finished then
        reason = "unfinished"
      else
        -- 检查年龄
        local updated_at = data.updated_at
        if updated_at then
          -- 解析 ISO 8601 时间戳
          local year, month, day, hour, min, sec = updated_at:match("(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)")
          if year then
            local file_time = os.time({
              year = tonumber(year),
              month = tonumber(month),
              day = tonumber(day),
              hour = tonumber(hour),
              min = tonumber(min),
              sec = tonumber(sec),
            })
            local age = now - file_time
            if age > max_age_seconds then
              should_delete = true
              reason = string.format("age=%d days", math.floor(age / 86400))
            else
              reason = string.format("age=%d days (< %d)", math.floor(age / 86400), max_age_days)
            end
          else
            reason = "invalid timestamp"
          end
        else
          -- 没有时间戳，根据文件名判断
          local session_id = data.id or ""
          local date_part = session_id:match("ma_(%d%d%d%d%d%d%d%d)")
          if date_part then
            local year = tonumber(date_part:sub(1, 4))
            local month = tonumber(date_part:sub(5, 6))
            local day = tonumber(date_part:sub(7, 8))
            local file_time = os.time({ year = year, month = month, day = day, hour = 0, min = 0, sec = 0 })
            local age = now - file_time
            if age > max_age_seconds then
              should_delete = true
              reason = string.format("age=%d days (from id)", math.floor(age / 86400))
            end
          else
            reason = "no timestamp"
          end
        end
      end

      if should_delete then
        if dry_run then
          table.insert(result.deleted, data.id .. " (dry-run): " .. reason)
        else
          local ok = vim.fn.delete(file)
          if ok == 0 then
            table.insert(result.deleted, data.id .. ": " .. reason)
            log:debug("[SessionManager] Deleted session: %s (%s)", data.id, reason)
          else
            table.insert(result.errors, data.id .. ": failed to delete")
          end
        end
      else
        table.insert(result.kept, data.id .. ": " .. reason)
      end
    end
  end

  log:info(
    "[SessionManager] Cleanup complete: deleted=%d, kept=%d, errors=%d",
    #result.deleted,
    #result.kept,
    #result.errors
  )

  return result
end

--- 获取存储统计信息
---@return table stats {total: number, finished: number, unfinished: number, size_bytes: number}
function M.get_stats()
  local stats = {
    total = 0,
    finished = 0,
    unfinished = 0,
    size_bytes = 0,
  }

  local dir = M.get_storage_dir()
  if vim.fn.isdirectory(dir) == 0 then
    return stats
  end

  local files = vim.fn.glob(dir .. "/ma_*.json", false, true)
  for _, file in ipairs(files) do
    stats.total = stats.total + 1
    stats.size_bytes = stats.size_bytes + vim.fn.getfsize(file)

    local data, _ = read_json_file(file)
    if data then
      if data.state and data.state.is_finished then
        stats.finished = stats.finished + 1
      else
        stats.unfinished = stats.unfinished + 1
      end
    end
  end

  return stats
end

--- 创建版本信息
---@return table version 版本信息
function M.create_version_info()
  return {
    version = M.VERSION,
    name = "session_manager",
  }
end

return M
