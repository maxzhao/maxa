-- ability_hooks/registry.lua
-- 全局 Hook 注册管理
--
-- 职责：
--   1. 存储所有注册的 hook（按事件名索引）
--   2. 管理 cascade 的 parent_chain（引用方式）
--   3. 注册/注销 autocmd
--   4. 去重（同一 event + 同一 hook 文件路径不重复注册）
--   5. chat 关闭时清理

local M = {}

--- 全局状态
---@class AbilityHookRegistryState
local state = {
  --- 按事件名索引的 hook 列表
  --- key: event_name, value: [{hook, autocmd_id, scope, bound_chat_id}]
  ---@type table<string, table[]>
  hooks = {},

  --- cascade parent chain
  --- key: child_chat_id, value: [parent_id, grandparent_id, ...]
  ---@type table<number, number[]>
  parent_chain = {},

  --- cascade hooks 注册表
  --- key: chat_id, value: [{hook}]（只在 load_ability 的原始 chat 上记录）
  ---@type table<number, table[]>
  cascade_hooks = {},
}

--- 生成去重 key
---@param event_name string
---@param hook_path string
---@param scope string
---@param chat_id number|nil
---@return string
local function dedup_key(event_name, hook_path, scope, chat_id)
  return string.format("%s::%s::%s::%s", event_name, hook_path, scope, tostring(chat_id or "global"))
end

--- 检查是否已注册（去重）
---@param event_name string
---@param hook_path string
---@param scope string
---@param chat_id number|nil
---@return boolean
function M.is_registered(event_name, hook_path, scope, chat_id)
  local entries = state.hooks[event_name]
  if not entries then
    return false
  end
  local key = dedup_key(event_name, hook_path, scope, chat_id)
  for _, entry in ipairs(entries) do
    if entry.dedup_key == key then
      return true
    end
  end
  return false
end

--- 注册一个 hook
---@param hook table 解析后的 hook（来自 parser）
---@param chat_id number|nil 绑定的 chat id（session/cascade 模式）
---@return boolean success
function M.register(hook, chat_id)
  local event_name = hook.event_name
  local scope = hook.scope

  -- 去重
  if M.is_registered(event_name, hook.path, scope, chat_id) then
    return false
  end

  -- 创建 autocmd
  local autocmd_id = vim.api.nvim_create_autocmd("User", {
    pattern = "AbilityHook" .. event_name,
    callback = function(args)
      local data = args.data or {}
      local phase = data._ability_hook_phase or "post"
      if (hook.inject_at or "post") ~= phase then
        return
      end
      require("maxa.abilities.hooks.injector").on_event(args, hook, scope, chat_id)
    end,
    desc = string.format("[ability_hooks] %s (%s) from %s", event_name, scope, hook.path),
  })

  -- 记录注册
  if not state.hooks[event_name] then
    state.hooks[event_name] = {}
  end

  local entry = {
    hook = hook,
    autocmd_id = autocmd_id,
    scope = scope,
    bound_chat_id = chat_id,
    dedup_key = dedup_key(event_name, hook.path, scope, chat_id),
  }

  table.insert(state.hooks[event_name], entry)

  -- cascade 模式：记录到 cascade_hooks
  if scope == "cascade" and chat_id then
    if not state.cascade_hooks[chat_id] then
      state.cascade_hooks[chat_id] = {}
    end
    table.insert(state.cascade_hooks[chat_id], hook)
  end

  return true
end

--- 注销指定 chat 的所有 session/cascade hooks
---@param chat_id number
function M.unregister_chat(chat_id)
  for event_name, entries in pairs(state.hooks) do
    local kept = {}
    for _, entry in ipairs(entries) do
      if entry.bound_chat_id == chat_id then
        -- 删除 autocmd
        pcall(vim.api.nvim_del_autocmd, entry.autocmd_id)
      else
        table.insert(kept, entry)
      end
    end
    state.hooks[event_name] = #kept > 0 and kept or nil
  end

  -- 清理 cascade 相关
  state.cascade_hooks[chat_id] = nil
  state.parent_chain[chat_id] = nil
end

---Replace Chat-local on-load hooks for one Ability without touching startup or
---global registrations.
---@param chat_id number
---@param ability_name string
function M.unregister_ability(chat_id, ability_name)
  for event_name, entries in pairs(state.hooks) do
    local kept = {}
    for _, entry in ipairs(entries) do
      local remove = entry.bound_chat_id == chat_id and entry.hook and entry.hook.ability_name == ability_name
      if remove then
        pcall(vim.api.nvim_del_autocmd, entry.autocmd_id)
      else
        kept[#kept + 1] = entry
      end
    end
    state.hooks[event_name] = #kept > 0 and kept or nil
  end
  local cascade = state.cascade_hooks[chat_id]
  if cascade then
    local kept = {}
    for _, hook in ipairs(cascade) do
      if hook.ability_name ~= ability_name then
        kept[#kept + 1] = hook
      end
    end
    state.cascade_hooks[chat_id] = #kept > 0 and kept or nil
  end
end

--- 注册 parent chain（子代理创建时调用）
---@param parent_chat_id number
---@param child_chat_id number
function M.register_parent_chain(parent_chat_id, child_chat_id)
  local parent_ancestors = state.parent_chain[parent_chat_id] or {}
  -- 子 chat 的链 = [parent_id, ...parent_ancestors]
  local chain = { parent_chat_id }
  for _, ancestor in ipairs(parent_ancestors) do
    table.insert(chain, ancestor)
  end
  state.parent_chain[child_chat_id] = chain
end

--- 检查 chat_id 是否在某个 cascade 家族中
--- 沿 parent_chain 向上追溯，查找 cascade_hooks
---@param chat_id number
---@return table[] hooks 匹配的 cascade hooks
function M.get_cascade_hooks_for(chat_id)
  local result = {}

  -- 先检查自身
  if state.cascade_hooks[chat_id] then
    for _, hook in ipairs(state.cascade_hooks[chat_id]) do
      table.insert(result, hook)
    end
  end

  -- 沿 parent_chain 向上追溯
  local chain = state.parent_chain[chat_id]
  if chain then
    for _, ancestor_id in ipairs(chain) do
      if state.cascade_hooks[ancestor_id] then
        for _, hook in ipairs(state.cascade_hooks[ancestor_id]) do
          table.insert(result, hook)
        end
      end
    end
  end

  return result
end

--- 检查 chat_id 是否在 cascade 范围内
---@param chat_id number
---@param hook table
---@return boolean
function M.is_in_cascade(chat_id, hook)
  -- 检查自身是否有 cascade_hooks 包含此 hook
  if state.cascade_hooks[chat_id] then
    for _, h in ipairs(state.cascade_hooks[chat_id]) do
      if h.path == hook.path then
        return true
      end
    end
  end

  -- 沿 parent_chain 向上追溯
  local chain = state.parent_chain[chat_id]
  if chain then
    for _, ancestor_id in ipairs(chain) do
      if state.cascade_hooks[ancestor_id] then
        for _, h in ipairs(state.cascade_hooks[ancestor_id]) do
          if h.path == hook.path then
            return true
          end
        end
      end
    end
  end

  return false
end

--- 将父 chat 的 session hooks 复制注册到子 chat
--- fork_agent 创建的子代理应完全继承父代理的行为
---@param parent_chat_id number 父 chat id
---@param child_chat_id number 子 chat id
function M.inherit_session_hooks(parent_chat_id, child_chat_id, child_chat)
  local root = child_chat and child_chat.opts and (child_chat.opts.project_root or child_chat.opts.cwd)
  local inherited = {}
  for _, entries in pairs(state.hooks) do
    for _, entry in ipairs(entries) do
      if entry.scope == "session" and entry.bound_chat_id == parent_chat_id then
        local allowed = true
        if entry.hook.ability_name and root then
          allowed = require("maxa.project.settings").check_ability(root, entry.hook.ability_name) == true
        end
        if allowed then inherited[#inherited + 1] = entry.hook end
      end
    end
  end
  for _, hook in ipairs(inherited) do M.register(hook, child_chat_id) end
end

--- 获取所有注册的 hooks（调试用）
---@return table
function M.get_state()
  return {
    hooks = state.hooks,
    parent_chain = state.parent_chain,
    cascade_hooks = state.cascade_hooks,
  }
end

--- 重置所有状态（测试/重启用）
function M.reset()
  -- 清理所有 autocmd
  for _, entries in pairs(state.hooks) do
    for _, entry in ipairs(entries) do
      pcall(vim.api.nvim_del_autocmd, entry.autocmd_id)
    end
  end
  state.hooks = {}
  state.parent_chain = {}
  state.cascade_hooks = {}
end

return M
