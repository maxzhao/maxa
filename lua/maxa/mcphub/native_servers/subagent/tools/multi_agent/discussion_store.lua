-- filepath: lua/maxa/mcphub/native_servers/subagent/tools/multi_agent/discussion_store.lua
-- DiscussionStore: 管理 Multi-Agent 讨论记录
-- 用于阻塞式 Handoff 机制中存储和检索讨论历史

---@class DiscussionEntry
---@field agent string Agent 名称
---@field message string 对 target 说的话
---@field sequence number 内部序号（不暴露给 Agent）

---@class DiscussionStore
---@field _entries DiscussionEntry[] 按顺序存储的讨论记录
local DiscussionStore = {}
DiscussionStore.__index = DiscussionStore

--- 创建新的 DiscussionStore 实例
---@return DiscussionStore
function DiscussionStore.new()
  local self = setmetatable({
    _entries = {},
  }, DiscussionStore)
  return self
end

--- 添加讨论记录
---@param agent string Agent 名称
---@param message string 对 target 说的话
function DiscussionStore:add_entry(agent, message)
  table.insert(self._entries, {
    agent = agent,
    message = message,
    sequence = #self._entries + 1, -- 从 1 开始的序号
  })
end

--- 获取指定序号之后的所有讨论记录
--- 用于 handoff 返回时构建 discussion_after
---@param sequence number 起始序号（不包含）
---@return table[] 结构化讨论记录数组 [{agent, message}, ...]
function DiscussionStore:get_entries_after(sequence)
  local result = {}
  for _, entry in ipairs(self._entries) do
    if entry.sequence > sequence then
      -- 返回时不包含 sequence（内部字段）
      table.insert(result, {
        agent = entry.agent,
        message = entry.message,
      })
    end
  end
  return result
end

--- 获取所有讨论记录
---@return table[] 结构化讨论记录数组
function DiscussionStore:get_all_entries()
  local result = {}
  for _, entry in ipairs(self._entries) do
    table.insert(result, {
      agent = entry.agent,
      message = entry.message,
    })
  end
  return result
end

--- 获取讨论记录数量（用于 maxTurns/minTurns 检查）
---@return number
function DiscussionStore:get_entry_count()
  return #self._entries
end

--- 获取当前序号（用于 handoff 时记录起始位置）
---@return number 当前最大序号，空 store 返回 0
function DiscussionStore:get_current_sequence()
  return #self._entries
end

--- 获取其他 Agent 的讨论记录（用于构建当前 Agent 的上下文）
--- 返回所有不属于指定 Agent 的记录，按时间顺序排列
---@param agent_name string 当前 Agent 名称（将被排除）
---@return table[] 其他 Agent 的讨论记录
function DiscussionStore:get_entries_for_agent(agent_name)
  local result = {}
  for _, entry in ipairs(self._entries) do
    -- 排除自己的记录，只返回其他 Agent 的
    if entry.agent ~= agent_name then
      table.insert(result, {
        agent = entry.agent,
        message = entry.message,
      })
    end
  end
  return result
end

--- 从保存的数据恢复讨论记录
--- 用于会话持久化恢复
---@param saved_data table[] 保存的讨论数据 [{agent, message, ...}]
function DiscussionStore:restore(saved_data)
  -- 清空现有数据
  self._entries = {}

  -- 恢复保存的数据
  if saved_data and type(saved_data) == "table" then
    for i, entry in ipairs(saved_data) do
      table.insert(self._entries, {
        agent = entry.agent,
        message = entry.message,
        sequence = i,
      })
    end
  end
end

return DiscussionStore
