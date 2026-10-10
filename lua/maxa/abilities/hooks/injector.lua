-- ability_hooks/injector.lua
-- 事件触发时的注入逻辑
--
-- 职责：
--   1. 从 event args 获取 chat 实例
--   2. 按 scope 过滤（global / session / cascade parent_chain 追溯）
--   3. 按 filter 过滤
--   4. opts.once 去重检查
--   5. opts.ephemeral 临时消息支持
--   6. 同事件多 hook 按 role 分组合并注入（防止多轮对话断裂）
--   7. 调用 chat:add_message() 注入（附带 context.ability_hook meta）

local M = {}

--- once 去重状态：{ [chat_id] = { [hook_path] = true } }
local fired_once = {}

--- 批量注入队列：{ [chat_id] = { chat, entries[] } }
--- 同一 vim.schedule tick 内收集的 hook 条目
---@type table<number, { chat: table, entries: table[] }>
local pending_batch = {}

--- 延迟注入队列：工具执行期间积累的 hook 条目，等待 ToolsFinished 后注入
--- 防止 hook 消息插入在 tool_call 结果之间，破坏消息序列
---@type table<number, { chat: table, entries: table[] }>
local deferred_batch = {}

--- ToolsFinished 监听器是否已注册（全局单例）
local deferred_listener_active = false

--- 从 event args 获取 chat 实例
---@param args table autocmd callback 参数
---@return table|nil chat Maxa AI chat 对象
local function get_chat_from_event(args)
  local data = args.data
  if not data then
    return nil
  end

  local bufnr = data.bufnr
  if not bufnr then
    return nil
  end

  local ok, maxa_ai = pcall(require, "maxa")
  if not ok then
    return nil
  end

  -- buf_get_chat 返回 chat 对象或 nil
  if maxa_ai.buf_get_chat then
    return maxa_ai.buf_get_chat(bufnr)
  end

  return nil
end

--- 注册 ephemeral 消息的清理回调
--- 在 LLM 响应完成后移除 _meta.ephemeral 消息
---@param chat table Maxa AI chat 对象
local function register_ephemeral_cleanup(chat)
  -- 防止重复注册（同一轮多个 ephemeral 消息共用一个清理）
  if chat._ability_hook_ephemeral_cleanup then
    return
  end
  chat._ability_hook_ephemeral_cleanup = true

  -- 监听下一个 agent 完成或 chat 响应事件
  vim.api.nvim_create_autocmd("User", {
    pattern = { "MaxaAIAgent", "MaxaAIChatResponse" },
    once = true,
    callback = function(ev)
      chat._ability_hook_ephemeral_cleanup = nil

      if not chat.messages then
        return
      end

      local i = 1
      while i <= #chat.messages do
        local msg = chat.messages[i]
        if msg._meta and msg._meta.ephemeral then
          -- once + ephemeral → 替换为 tombstone（保留 once 状态）
          local sk = msg.context and msg.context.ability_hook
          -- 支持合并消息中的 paths 数组
          local once_path = nil
          if sk and sk.once then
            once_path = sk.path
          end
          -- 合并消息的 once 路径在 ability_hook_once_paths 中
          local once_paths = msg.context and msg.context.ability_hook_once_paths

          if once_path then
            chat.messages[i] = {
              role = "user",
              content = "[ability_hook:state]",
              _meta = { tag = "ability_hook_tombstone" },
              context = { ability_hook_once = { path = once_path } },
              opts = { visible = false },
            }
            i = i + 1
          elseif once_paths and #once_paths > 0 then
            -- 合并消息中有多个 once hook → 生成多个仅供内部恢复的 tombstone。
            for idx, op in ipairs(once_paths) do
              local tombstone = {
                role = "user",
                content = "[ability_hook:state]",
                _meta = { tag = "ability_hook_tombstone" },
                context = { ability_hook_once = { path = op } },
                opts = { visible = false },
              }
              if idx == 1 then
                chat.messages[i] = tombstone
              else
                table.insert(chat.messages, i + idx - 1, tombstone)
              end
            end
            i = i + #once_paths
          else
            table.remove(chat.messages, i)
          end
        else
          i = i + 1
        end
      end
    end,
  })
end

--- 直接注入单个 hook 的消息（单 hook 快路径，保持原始行为）
---@param chat table Maxa AI chat 对象
---@param entry table { hook, prompts, visible, is_ephemeral, is_once, ability_hook_context, meta }
local function inject_single(chat, entry)
  for _, prompt in ipairs(entry.prompts or {}) do
    chat:add_message(
      { role = prompt.role, content = prompt.content },
      { visible = entry.visible }
    )

    local new_msg = chat.messages[#chat.messages]
    new_msg.context = entry.ability_hook_context

    local prompt_meta = type(prompt._meta) == "table" and prompt._meta or nil
    local entry_meta = type(entry.meta) == "table" and entry.meta or nil
    if prompt_meta or entry_meta or entry.is_ephemeral then
      new_msg._meta = vim.tbl_deep_extend("force", {}, new_msg._meta or {}, entry_meta or {}, prompt_meta or {})
      if entry.is_ephemeral then
        new_msg._meta.ephemeral = true
      end
    end
  end

  if entry.is_ephemeral then
    register_ephemeral_cleanup(chat)
  end
end

--- 合并多个 hook 的消息并注入
--- 按 role 分组（user → llm），同 role 用分隔线拼接
---@param chat table Maxa AI chat 对象
---@param entries table[] hook 条目数组
local function inject_merged(chat, entries)
  -- 按 role 收集内容
  local groups = { user = {}, llm = {} }
  local group_meta = { user = {}, llm = {} }
  for _, entry in ipairs(entries) do
    for _, prompt in ipairs(entry.prompts or {}) do
      local role = prompt.role
      if groups[role] then
        table.insert(groups[role], prompt.content)
        if type(prompt._meta) == "table" then
          group_meta[role] = vim.tbl_deep_extend("force", group_meta[role], prompt._meta)
        end
      end
    end
  end

  -- 合并选项：任一 visible → visible；任一 ephemeral → ephemeral
  local merged_visible = false
  local merged_ephemeral = false
  local merged_meta = {}
  local once_paths = {}
  local all_paths = {}
  local event_name = entries[1].hook.event_name

  for _, entry in ipairs(entries) do
    if entry.visible then
      merged_visible = true
    end
    if entry.is_ephemeral then
      merged_ephemeral = true
    end
    if type(entry.meta) == "table" then
      merged_meta = vim.tbl_deep_extend("force", merged_meta, entry.meta)
    end
    if entry.is_once then
      table.insert(once_paths, entry.hook.path)
    end
    table.insert(all_paths, entry.hook.path)
  end

  -- 构建合并后的 context
  local merged_context = {
    ability_hook = {
      paths = all_paths,
      event = event_name,
      merged = true,
    },
  }
  -- once 路径记录（用于 ephemeral tombstone 恢复）
  if #once_paths > 0 then
    merged_context.ability_hook_once_paths = once_paths
  end

  -- 固定注入顺序：user → llm
  local role_order = { "user", "llm" }
  local injected_any = false

  for _, role in ipairs(role_order) do
    local contents = groups[role]
    if #contents > 0 then
      local merged_content
      if #contents == 1 then
        merged_content = contents[1]
      else
        merged_content = table.concat(contents, "\n\n---\n\n")
      end

      chat:add_message(
        { role = role, content = merged_content },
        { visible = merged_visible }
      )

      local new_msg = chat.messages[#chat.messages]
      new_msg.context = merged_context

      local role_meta = group_meta[role] or {}
      local has_meta = next(merged_meta) ~= nil or next(role_meta) ~= nil
      if has_meta or merged_ephemeral then
        new_msg._meta = vim.tbl_deep_extend("force", {}, new_msg._meta or {}, merged_meta, role_meta)
        if merged_ephemeral then
          new_msg._meta.ephemeral = true
        end
      end

      injected_any = true
    end
  end

  if injected_any and merged_ephemeral then
    register_ephemeral_cleanup(chat)
  end
end

--- 检查 chat 是否有未完成的工具调用结果
--- 扫描最后一条 LLM tool_calls 消息，检查是否所有 call_id 都有对应的 tool result
---@param chat table Maxa AI chat 对象
---@return boolean true 表示仍有未返回的 tool results
local function has_pending_tool_results(chat)
  local messages = chat.messages
  if not messages or #messages == 0 then
    return false
  end

  -- 从末尾找到最后一条带 tool_calls 的 LLM 消息
  for i = #messages, 1, -1 do
    local msg = messages[i]
    if msg.role == "llm" and msg.tools and msg.tools.calls and #msg.tools.calls > 0 then
      -- 收集所有期望的 call_id
      local pending_count = 0
      local expected = {}
      for _, call in ipairs(msg.tools.calls) do
        local call_id = call.call_id or call.id
        if call_id then
          expected[call_id] = true
          pending_count = pending_count + 1
        end
      end
      if pending_count == 0 then
        return false
      end

      -- 扣减已收到的 tool result
      for j = i + 1, #messages do
        local rmsg = messages[j]
        if rmsg.role == "tool" and rmsg.tools and rmsg.tools.call_id then
          if expected[rmsg.tools.call_id] then
            expected[rmsg.tools.call_id] = nil
            pending_count = pending_count - 1
          end
        end
      end

      return pending_count > 0
    end
  end

  return false
end

--- 刷新延迟队列（ToolsFinished 后调用）
---@param chat_id number
local function hook_allowed(chat, hook)
  if not hook.ability_name then return true end
  local root = chat.opts and (chat.opts.project_root or chat.opts.cwd)
  if not root then return false end
  local enabled, err = require("maxa.project.settings").ability_enabled(root, hook.ability_name)
  if err then vim.notify("[ability_hooks] " .. tostring(err), vim.log.levels.WARN) end
  if enabled ~= true then return false end
  local catalog, config_err = require("maxa.mcphub.utils.config_manager").get_effective_catalog(chat.opts.cwd or root)
  if not catalog then
    vim.notify("[ability_hooks] " .. tostring(config_err), vim.log.levels.WARN)
    return false
  end
  return true
end

local function filter_entries(chat, entries)
  return vim.tbl_filter(function(entry)
    if hook_allowed(chat, entry.hook) then return true end
    if entry.is_once and fired_once[chat.id] then fired_once[chat.id][entry.hook.path] = nil end
    return false
  end, entries)
end

local function flush_deferred(chat_id)
  local batch = deferred_batch[chat_id]
  deferred_batch[chat_id] = nil

  if not batch or not batch.entries or #batch.entries == 0 then
    return
  end

  local chat = batch.chat
  batch.entries = filter_entries(chat, batch.entries)
  if #batch.entries == 0 then return end

  if #batch.entries == 1 then
    inject_single(chat, batch.entries[1])
  else
    inject_merged(chat, batch.entries)
  end
end

--- 确保 ToolsFinished 监听器已注册（幂等，全局单例）
local function ensure_deferred_listener()
  if deferred_listener_active then
    return
  end
  deferred_listener_active = true

  vim.api.nvim_create_autocmd("User", {
    pattern = "MaxaAIToolsFinished",
    callback = function(args)
      local chat = get_chat_from_event(args)
      if not chat then
        return
      end

      if deferred_batch[chat.id] then
        flush_deferred(chat.id)
      end
    end,
  })
end

--- 刷新挂起的批量队列（vim.schedule 回调）
---@param chat_id number
local function flush_batch(chat_id)
  local batch = pending_batch[chat_id]
  pending_batch[chat_id] = nil

  if not batch or not batch.entries or #batch.entries == 0 then
    return
  end

  local chat = batch.chat
  batch.entries = filter_entries(chat, batch.entries)
  if #batch.entries == 0 then return end

  -- 如果 chat 仍有未返回的 tool results
  -- 防止 hook 消息插入在 tool_call 结果之间，破坏 tool_calls → tool_results 的连续性
  if has_pending_tool_results(chat) then
    if not deferred_batch[chat_id] then
      deferred_batch[chat_id] = { chat = chat, entries = {} }
    end
    vim.list_extend(deferred_batch[chat_id].entries, batch.entries)
    ensure_deferred_listener()
    return
  end

  if #batch.entries == 1 then
    -- 单 hook：原样注入，零行为变化
    inject_single(chat, batch.entries[1])
  else
    -- 多 hook：按 role 分组合并
    inject_merged(chat, batch.entries)
  end
end

--- 构建传给 Lua hook 的上下文。不要暴露 chat 对象，避免绕过统一注入管线。
---@param args table autocmd callback 参数
---@param hook table 解析后的 hook
---@param chat table Maxa AI chat 对象
---@return table
local function build_lua_ctx(args, hook, chat)
  local data = args.data or {}
  return {
    event_name = hook.event_name,
    data = data,
    bufnr = data.bufnr,
    chat_id = chat.id,
    hook_path = hook.path,
    ability_dir = hook.ability_dir,
  }
end

--- 校验 prompt 列表
---@param prompts any
---@param hook table
---@return table|nil
local function normalize_prompts(prompts, hook)
  if prompts == nil then
    return nil
  end
  if type(prompts) ~= "table" then
    vim.notify(
      string.format("[ability_hooks] Lua hook render must return a prompt list or nil: %s", hook.path),
      vim.log.levels.WARN
    )
    return nil
  end

  local normalized = {}
  for i, prompt in ipairs(prompts) do
    if type(prompt) ~= "table" then
      vim.notify(
        string.format("[ability_hooks] Lua hook prompt #%d must be a table: %s", i, hook.path),
        vim.log.levels.WARN
      )
      return nil
    end
    local role = prompt.role
    local content = prompt.content
    if role ~= "user" and role ~= "llm" then
      vim.notify(
        string.format("[ability_hooks] Lua hook prompt #%d has invalid role '%s': %s", i, tostring(role), hook.path),
        vim.log.levels.WARN
      )
      return nil
    end
    if type(content) ~= "string" or vim.trim(content) == "" then
      vim.notify(
        string.format("[ability_hooks] Lua hook prompt #%d content must be a non-empty string: %s", i, hook.path),
        vim.log.levels.WARN
      )
      return nil
    end
    local normalized_prompt = { role = role, content = content }
    if type(prompt._meta) == "table" then
      normalized_prompt._meta = vim.deepcopy(prompt._meta)
    end
    table.insert(normalized, normalized_prompt)
  end

  if #normalized == 0 then
    return nil
  end
  return normalized
end

--- 检查 once hook 是否已在当前 chat 触发过。
---@param chat table Maxa AI chat 对象
---@param hook table 解析后的 hook
---@return boolean
local function has_fired_once(chat, hook)
  local chat_id = chat.id
  -- 快速路径：内存中已记录
  if fired_once[chat_id] and fired_once[chat_id][hook.path] then
    return true
  end
  -- 惰性恢复：扫描 chat.messages 中的历史记录（仅首次触发时执行）
  for _, msg in ipairs(chat.messages or {}) do
    local sk = msg.context and msg.context.ability_hook
    if sk then
      -- 单 hook 消息
      if sk.path == hook.path and sk.once then
        fired_once[chat_id] = fired_once[chat_id] or {}
        fired_once[chat_id][hook.path] = true
        return true
      end
      -- 合并消息：检查 paths 数组
      if sk.paths then
        for _, p in ipairs(sk.paths) do
          if p == hook.path then
            fired_once[chat_id] = fired_once[chat_id] or {}
            fired_once[chat_id][hook.path] = true
            return true
          end
        end
      end
    end
    -- tombstone 标记（once + ephemeral 场景）
    local sko = msg.context and msg.context.ability_hook_once
    if sko and sko.path == hook.path then
      fired_once[chat_id] = fired_once[chat_id] or {}
      fired_once[chat_id][hook.path] = true
      return true
    end
  end
  return false
end

--- 记录 once hook 已触发。
---@param chat_id number
---@param hook table 解析后的 hook
local function mark_fired_once(chat_id, hook)
  fired_once[chat_id] = fired_once[chat_id] or {}
  fired_once[chat_id][hook.path] = true
end

--- 解析 hook prompts。Markdown 使用静态 prompts；Lua 调用 render(ctx)。
---@param args table autocmd callback 参数
---@param hook table 解析后的 hook
---@param chat table Maxa AI chat 对象
---@return table|nil prompts
local function resolve_prompts(args, hook, chat)
  if hook.kind == "lua" then
    local ctx = build_lua_ctx(args, hook, chat)
    local ok, prompts = pcall(hook.render, ctx)
    if not ok then
      vim.notify(
        string.format("[ability_hooks] Lua hook render failed for %s: %s", hook.path, tostring(prompts)),
        vim.log.levels.WARN
      )
      return nil
    end
    return normalize_prompts(prompts, hook)
  end

  return hook.prompts
end

--- 事件触发时的回调（由 registry 注册的 autocmd 调用）
---@param args table autocmd callback 参数
---@param hook table 解析后的 hook
---@param scope string "global" | "session" | "cascade"
---@param bound_chat_id number|nil 绑定的 chat id
function M.on_event(args, hook, scope, bound_chat_id)
  local chat = get_chat_from_event(args)
  if not chat then
    return
  end

  if not hook_allowed(chat, hook) then return end
  local chat_id = chat.id

  -- scope 过滤
  if scope == "session" then
    if chat_id ~= bound_chat_id then
      return
    end
  elseif scope == "cascade" then
    local registry = require("maxa.abilities.hooks.registry")
    if not registry.is_in_cascade(chat_id, hook) then
      return
    end
  end
  -- scope == "global": 不过滤

  -- filter 过滤
  if hook.kind == "lua" and type(hook.filter) == "function" then
    local ctx = build_lua_ctx(args, hook, chat)
    local ok, matched = pcall(hook.filter, ctx)
    if not ok then
      vim.notify(
        string.format("[ability_hooks] Lua hook filter failed for %s: %s", hook.path, tostring(matched)),
        vim.log.levels.WARN
      )
      return
    end
    if not matched then
      return
    end
  else
    local filter_mod = require("maxa.abilities.hooks.filter")
    if not filter_mod.matches(hook.filter, args.data or {}) then
      return
    end
  end

  -- once 去重检查：已触发则直接跳过；但首次触发必须等 render 有有效 prompts 后再记录。
  local is_once = hook.opts and hook.opts.once
  if is_once and has_fired_once(chat, hook) then
    return
  end

  local prompts = resolve_prompts(args, hook, chat)
  if not prompts or #prompts == 0 then
    return
  end

  if is_once then
    mark_fired_once(chat_id, hook)
  end

  -- 准备条目
  local visible = false
  if hook.opts and hook.opts.visible ~= nil then
    visible = hook.opts.visible
  end

  local is_ephemeral = hook.opts and hook.opts.ephemeral
  local hook_meta = hook.opts and hook.opts.meta

  local ability_hook_context = {
    ability_hook = {
      path = hook.path,
      event = hook.event_name,
      once = is_once or nil,
      ephemeral = is_ephemeral or nil,
    },
  }

  local entry = {
    hook = hook,
    prompts = prompts,
    visible = visible,
    is_ephemeral = is_ephemeral,
    is_once = is_once,
    ability_hook_context = ability_hook_context,
    meta = type(hook_meta) == "table" and hook_meta or nil,
  }

  -- 加入批量队列
  if not pending_batch[chat_id] then
    pending_batch[chat_id] = { chat = chat, entries = {} }
    -- 首次加入：注册 vim.schedule flush
    -- nvim_exec_autocmds 同步执行所有 callback 后，vim.schedule 回调才运行
    vim.schedule(function()
      flush_batch(chat_id)
    end)
  end

  table.insert(pending_batch[chat_id].entries, entry)
end

--- 立即刷新指定 chat 的挂起注入队列。
--- 用于 pre-submit hook：事件触发方需要在继续执行前确保 hook 消息已进入 chat.messages。
---@param chat_id number
function M.flush_chat(chat_id)
  if type(chat_id) ~= "number" then
    return
  end
  flush_batch(chat_id)
end

--- 清理指定 chat 的 once 状态（chat 关闭时调用）
---@param chat_id number
function M.clear_chat_state(chat_id)
  fired_once[chat_id] = nil
  pending_batch[chat_id] = nil
  deferred_batch[chat_id] = nil
end

--- 从消息中恢复 once 状态（历史恢复时调用）
---@param chat_id number
---@param messages table[] chat.messages
function M.restore_once_state(chat_id, messages)
  if not messages then
    return
  end

  for _, msg in ipairs(messages) do
    -- 恢复 context.ability_hook.once 标记的消息（单 hook）
    if msg.context and msg.context.ability_hook and msg.context.ability_hook.once then
      fired_once[chat_id] = fired_once[chat_id] or {}
      fired_once[chat_id][msg.context.ability_hook.path] = true
    end
    -- 恢复合并消息中的 once 路径
    if msg.context and msg.context.ability_hook_once_paths then
      for _, p in ipairs(msg.context.ability_hook_once_paths) do
        fired_once[chat_id] = fired_once[chat_id] or {}
        fired_once[chat_id][p] = true
      end
    end
    -- 恢复合并消息中的 paths（检查 once 状态）
    if msg.context and msg.context.ability_hook and msg.context.ability_hook.paths then
      -- 合并消息本身不带 once 标记，once 信息在 ability_hook_once_paths 中
      -- 但仍需遍历 paths 以支持历史兼容
    end
    -- 恢复 tombstone 标记
    if msg.context and msg.context.ability_hook_once then
      fired_once[chat_id] = fired_once[chat_id] or {}
      fired_once[chat_id][msg.context.ability_hook_once.path] = true
    end
  end
end

return M
