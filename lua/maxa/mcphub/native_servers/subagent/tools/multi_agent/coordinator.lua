-- filepath: lua/maxa/mcphub/native_servers/subagent/tools/multi_agent/coordinator.lua
-- MultiAgentCoordinator: 核心协调器，管理多 Agent 执行流程和事件驱动
-- 用于 Multi-Agent 协作系统的中央控制

local DiscussionStore = require("maxa.mcphub.native_servers.subagent.tools.multi_agent.discussion_store")
local SessionManager = require("maxa.mcphub.native_servers.subagent.tools.multi_agent.session_manager")
local utils = require("maxa.mcphub.native_servers.subagent.utils")
local log = require("maxa.utils.log")

---@class CoordinatorConfig
---@field agents table[] Agent 配置列表 [{name, role, soul?, goal_prompt?, adapter?, icon?, restrict_tools?}]
---@field messages? table[] 共享背景输入
---@field shared_background? table[] 已加载的共享背景快照（恢复使用）
---@field routing? table 路由配置 {initial_agent?: string}
---@field termination? table 终止配置 {maxTurns?: number, minTurns?: number, max_messages?: number}
---@field final_agent? "fork"|"run" Phase 2 Agent 类型 (必选，启用 Phase 2)
---@field final_prompt? string Phase 2 追加到 Display Chat messages 末尾的 prompt (必选)
---@field final_max_turns? number Phase 2 最大轮次 (可选，默认无限制)
---@field final_agent_config? table Phase 2 run 模式专用配置 {inherit?: boolean, adapter?: string, soul?: string, restrict_tools?: string[]}
---@field title? string Display Chat / history title

---@class MultiAgentCoordinator
---@field agents table<string, AgentChat> Agent 实例映射 (name -> AgentChat)
---@field agent_configs table[] 原始 Agent 配置列表
---@field display_chat table|nil Display Chat 实例
---@field display_adapter table|nil DisplayAdapter 实例
---@field discussion_store DiscussionStore 讨论记录管理器
---@field current_agent string|nil 当前执行的 Agent 名称
---@field round number 当前轮次
---@field is_running boolean 是否正在运行
---@field is_finished boolean 是否已结束
---@field termination table 终止配置
---@field initial_agent string|nil 初始 Agent 名称
---@field task string|nil 讨论任务
---@field _handlers table<string, function[]> 事件处理器映射
---@field on_complete function|nil 完成回调
---@field on_error function|nil 错误回调
---@field session_id string|nil 会话 ID（用于持久化）
---@field _session table|nil 会话元数据
local Coordinator = {}
Coordinator.__index = Coordinator

--- 创建新的 MultiAgentCoordinator 实例
---@param opts CoordinatorConfig
---@return MultiAgentCoordinator
function Coordinator.new(opts)
  assert(opts.agents and #opts.agents > 0, "Coordinator requires at least one agent")

  -- 处理 termination 配置，设置默认值
  -- 任务 10.1: 重命名 max_rounds -> maxTurns, min_rounds -> minTurns
  local termination = opts.termination or {}
  termination.maxTurns = termination.maxTurns or 10
  termination.minTurns = termination.minTurns or 1

  local self = setmetatable({
    -- Agent 管理
    agents = {},
    agent_configs = {},

    -- Display Chat
    display_chat = nil,
    display_adapter = nil,

    -- 讨论记录管理
    discussion_store = nil,

    -- 状态
    current_agent = nil,
    round = 0,
    is_running = false,
    is_finished = false,
    is_paused = false,

    -- 配置
    termination = termination,
    initial_agent = opts.routing and opts.routing.initial_agent or nil,
    task = nil,

    -- 事件处理
    _handlers = {},

    -- 任务 10.1: 等待队列管理
    _pending_handoffs = {}, -- 等待中的 handoff 回调队列
    _sequence = 0, -- 内部发言计数器

    -- 回调
    on_complete = nil,
    on_error = nil,
    _error_reported = false,

    -- 持久化
    session_id = nil,
    _session = nil,
    title = opts.title,
  }, Coordinator)

  self:_init(opts)
  return self
end

--- 初始化 Coordinator
---@param opts CoordinatorConfig
function Coordinator:_init(opts)
  -- 保存 Agent 配置
  for _, config in ipairs(opts.agents) do
    table.insert(self.agent_configs, {
      name = config.name,
      role = config.role,
      soul = config.soul,
      soul_prompt = config.soul_prompt,
      soul_file = config.soul_file,
      goal_prompt = config.goal_prompt,
      adapter = config.adapter, -- LLM adapter 预设（nil 表示继承父代理）
      icon = config.icon,
      restrict_tools = config.restrict_tools, -- 限定工具列表（除 handoff 外）
    })
  end

  self._shared_background = opts.shared_background and vim.deepcopy(opts.shared_background)
    or utils.prepare_background_messages(opts.messages)

  -- 创建 DiscussionStore
  self.discussion_store = DiscussionStore.new()

  -- 注意：Display Chat 延迟到 start() 中创建
  -- 因为此时 _parent_window_manager 还没有设置

  -- 注册 handoff 事件处理器
  self:on("handoff", function(event)
    self:_on_handoff(event)
  end)

  -- Phase 2 配置
  self._final_agent = opts.final_agent -- "fork" | "run" | nil
  self._final_prompt = opts.final_prompt
  self._final_max_turns = utils.normalize_max_turns(opts.final_max_turns, math.huge)
  self._final_agent_config = opts.final_agent_config -- run 模式专用 {agent?, tools?}
  self._phase2_turn = 0 -- Phase 2 当前轮次
  self._in_phase2 = false -- 是否在 Phase 2 中
end

--- 创建 Display Chat 用于显示讨论过程
function Coordinator:_create_display_chat()
  local ok, Chat = pcall(require, "maxa.interactions.chat")
  if not ok then
    error("Failed to load Display Chat module: " .. tostring(Chat))
  end

  local display_adapter_module = require("maxa.mcphub.native_servers.subagent.tools.multi_agent.display_adapter")

  local adapter = self._parent_adapter or utils.resolve_adapter_by_key(nil)
  if not adapter then
    error("Failed to resolve Display Chat adapter")
  end
  self.display_adapter = display_adapter_module.create(adapter)

  -- 生成 save_id（用于 history 插件）
  local history_utils = require("maxa.session.history.utils")
  local save_id = history_utils.generate_save_id({ prefix = "multi_agent" })

  -- 使用调用方显式标题；旧会话兜底保留兼容
  local title = self.title or "Multi-Agent: Discussion"

  local parent = self._parent_chat
  local context = vim.deepcopy(parent and parent.buffer_context or {})
  local parent_opts = parent and parent.opts or {}
  context.cwd = parent_opts.cwd or context.cwd
  context.project_root = parent_opts.project_root or context.project_root

  -- Shared snapshot is also the final executor's background. Restored public
  -- records are copied without participant-private handoff notes.
  local messages = vim.deepcopy(self._shared_background)
  for _, entry in ipairs(self.discussion_store:get_all_entries()) do
    table.insert(messages, { role = "user", content = entry.agent .. ": " .. entry.message })
  end
  local chat_ok, chat = pcall(Chat.new, {
    adapter = self.display_adapter,
    messages = utils.build_sub_agent_render_messages(messages),
    buffer_context = context,
    cwd = context.cwd,
    project_root = context.project_root,
    headless = true,
    agent_child = true,
    agent_parent = parent,
    ignore_system_prompt = true,
    -- 禁用工具和自动提交
    tools = {},
    auto_submit = false,
    stop_context_insertion = true,
    -- 禁用 intro message (hints)
    intro_message = "",
    -- ⭐ 设置 save_id 和 title，用于 history 插件
    save_id = save_id,
    title = title,
    -- ⭐ 设置 title_refresh_count 为最大值，阻止 history 插件自动刷新标题
    title_refresh_count = 999,
  })

  if not chat_ok or not chat then
    self.display_adapter = nil
    error("Failed to create display chat: " .. (chat_ok and "Chat.new returned nil" or tostring(chat)))
  end

  self.display_chat = chat
  chat.messages = messages
  if chat.tools then chat.tools.messages = messages end
  utils.bind_sub_agent_render_messages(chat)

  -- ⭐ 确保 opts 中的标题设置正确
  if chat.opts then
    chat.opts.save_id = chat.opts.save_id or save_id
    chat.opts.title = chat.opts.title or title
    chat.opts.title_refresh_count = 999
  end

  utils.apply_tools_override(chat, {})

  -- ⭐ 保护 Display Chat 的 buffer，防止被意外删除
  self:_protect_display_chat_buffer(chat)

  -- 设置 Multi-Agent Tab 布局（新 Tab，左右分割）
  self:_setup_multi_agent_tab()

  log:debug("[Coordinator] Display chat created with save_id=%s, title=%s", save_id, title)
end

--- 保护 Display Chat 的 buffer，防止被意外删除
--- 新方案：简化保护机制，只标记和 Hook close 方法
---@param chat table Chat 实例
function Coordinator:_protect_display_chat_buffer(chat)
  if not chat then
    return
  end

  -- 标记为 multi-agent 使用中
  if chat.bufnr and vim.api.nvim_buf_is_valid(chat.bufnr) then
    vim.b[chat.bufnr]._multi_agent_protected = true
  end

  -- Hook Chat 的 close 方法，防止意外删除 buffer
  local original_close = chat.close
  chat._original_close = original_close
  chat.close = function(self_chat)
    -- 如果被保护，只隐藏窗口，不删除 buffer
    if
      self_chat.bufnr
      and vim.api.nvim_buf_is_valid(self_chat.bufnr)
      and vim.b[self_chat.bufnr]._multi_agent_protected
    then
      log:debug("[Coordinator] Display buffer %d is protected, hiding window instead of closing", self_chat.bufnr)
      if self_chat.ui and self_chat.ui.winnr and vim.api.nvim_win_is_valid(self_chat.ui.winnr) then
        pcall(vim.api.nvim_win_hide, self_chat.ui.winnr)
      end
      return
    end
    -- 否则调用原始 close
    return original_close(self_chat)
  end
end

--- 设置 Multi-Agent Tab 布局
--- 创建新 Tab，左侧 Display Chat，右侧 Active AgentChat
--- Multi-Agent tab 布局实现
function Coordinator:_setup_multi_agent_tab()
  if not self.display_chat or not self.display_chat.bufnr then
    return
  end

  -- 关闭 Chat.new 创建的窗口（如果有）
  local chat_winnr = self.display_chat.ui and self.display_chat.ui.winnr
  if chat_winnr and vim.api.nvim_win_is_valid(chat_winnr) then
    vim.api.nvim_win_close(chat_winnr, false) -- false = 不强制关闭，保留 buffer
  end

  -- 记录父 Tab
  self._tab_info = {
    parent_tabnr = vim.api.nvim_get_current_tabpage(),
    tabnr = nil,
    display_winnr = nil,
    agent_winnr = nil,
  }

  -- 创建新 Tab
  vim.cmd("tabnew")
  self._tab_info.tabnr = vim.api.nvim_get_current_tabpage()

  -- 左侧窗口放 Display Chat buffer
  local left_winnr = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(left_winnr, self.display_chat.bufnr)
  vim.wo[left_winnr].wrap = true
  if self.display_chat.ui then
    self.display_chat.ui.winnr = left_winnr
  end
  self._tab_info.display_winnr = left_winnr

  -- 右侧垂直分割窗口（初始为空 scratch buffer）
  vim.cmd("botright vsplit")
  local right_winnr = vim.api.nvim_get_current_win()
  -- 创建 scratch buffer 显示初始提示
  local scratch_bufnr = vim.api.nvim_create_buf(false, true) -- nofile, scratch
  vim.bo[scratch_bufnr].buftype = "nofile"
  vim.bo[scratch_bufnr].bufhidden = "wipe"
  vim.api.nvim_buf_set_lines(scratch_bufnr, 0, -1, false, {
    "",
    "  🤖 Multi-Agent 讨论",
    "",
    "  等待第一个 Agent 开始...",
    "",
  })
  vim.api.nvim_win_set_buf(right_winnr, scratch_bufnr)
  vim.wo[right_winnr].wrap = true
  self._tab_info.agent_winnr = right_winnr
  self._tab_info.scratch_bufnr = scratch_bufnr

  -- 聚焦到左侧 Display Chat
  vim.api.nvim_set_current_win(left_winnr)

  log:debug(
    "[Coordinator] Multi-Agent tab created: tabnr=%d, display_winnr=%d, agent_winnr=%d",
    self._tab_info.tabnr,
    left_winnr,
    right_winnr
  )
end

--- 恢复 Multi-Agent Tab 的布局
--- Chat.new 的 close_last_chat 可能隐藏了 Display Chat 窗口
--- 确保左侧 Display Chat 和右侧 Agent 窗口都存在
function Coordinator:_restore_tab_layout()
  if not self._tab_info then
    return
  end

  -- 确保我们在 Multi-Agent Tab 中
  if self._tab_info.tabnr and vim.api.nvim_tabpage_is_valid(self._tab_info.tabnr) then
    local current_tab = vim.api.nvim_get_current_tabpage()
    if current_tab ~= self._tab_info.tabnr then
      vim.api.nvim_set_current_tabpage(self._tab_info.tabnr)
    end
  end

  -- 获取当前 Tab 中的窗口列表
  local wins = vim.api.nvim_tabpage_list_wins(self._tab_info.tabnr or vim.api.nvim_get_current_tabpage())

  -- 检查 Display Chat 窗口是否还有效
  local display_winnr = self._tab_info.display_winnr
  local display_valid = display_winnr and vim.api.nvim_win_is_valid(display_winnr)

  -- 检查 Agent 窗口是否还有效
  local agent_winnr = self._tab_info.agent_winnr
  local agent_valid = agent_winnr and vim.api.nvim_win_is_valid(agent_winnr)

  -- 关闭所有不属于我们管理的窗口（可能被 Chat.new 创建的）
  local managed_wins = {}
  if display_valid then managed_wins[display_winnr] = true end
  if agent_valid then managed_wins[agent_winnr] = true end

  for _, winnr in ipairs(wins) do
    if not managed_wins[winnr] then
      -- 检查这个窗口是否显示了我们不需要的 buffer
      local bufnr = vim.api.nvim_win_get_buf(winnr)
      local is_our_display = self.display_chat and self.display_chat.bufnr == bufnr
      local is_our_agent = false
      for _, agent in pairs(self.agents) do
        if agent.chat and agent.chat.bufnr == bufnr then
          is_our_agent = true
          break
        end
      end

      if is_our_display then
        -- 这是 Display Chat 的 buffer 在另一个窗口中
        if not display_valid then
          -- Display Chat 窗口无效，使用这个窗口
          self._tab_info.display_winnr = winnr
          display_winnr = winnr
          display_valid = true
        else
          -- 已有 Display Chat 窗口，关闭重复的
          pcall(vim.api.nvim_win_close, winnr, true)
        end
      elseif not is_our_agent and not is_our_display then
        -- 不是我们管理的窗口（可能是父 Chat 被打开了），关闭它
        pcall(vim.api.nvim_win_close, winnr, true)
      end
    end
  end

  -- 如果 Display Chat 窗口无效，重新创建
  if not display_valid and self.display_chat and self.display_chat.bufnr
    and vim.api.nvim_buf_is_valid(self.display_chat.bufnr) then
    -- 获取当前 Tab 中的第一个窗口
    local first_win = vim.api.nvim_tabpage_list_wins(
      self._tab_info.tabnr or vim.api.nvim_get_current_tabpage()
    )[1]
    if first_win then
      vim.api.nvim_win_set_buf(first_win, self.display_chat.bufnr)
      vim.wo[first_win].wrap = true
      self._tab_info.display_winnr = first_win
      if self.display_chat.ui then
        self.display_chat.ui.winnr = first_win
      end
      display_winnr = first_win
      display_valid = true
    end
  end

  -- 如果 Agent 窗口无效，重新创建右侧分割
  if not agent_valid and display_valid then
    vim.api.nvim_set_current_win(display_winnr)
    vim.cmd("botright vsplit")
    agent_winnr = vim.api.nvim_get_current_win()
    vim.wo[agent_winnr].wrap = true
    self._tab_info.agent_winnr = agent_winnr
    log:debug("[Coordinator] Recreated agent window: winnr=%d", agent_winnr)
  end
end

--- 切换右侧窗口到指定 AgentChat 的 buffer
---@param agent_name string Agent 名称
function Coordinator:_switch_agent_window(agent_name)
  if not self._tab_info then
    return
  end

  local agent = self.agents[agent_name]
  if not agent or not agent.chat or not agent.chat.bufnr then
    log:debug("[Coordinator] Agent %s has no valid chat buffer, keeping current view", agent_name)
    return
  end

  if not vim.api.nvim_buf_is_valid(agent.chat.bufnr) then
    log:warn("[Coordinator] Agent %s buffer is invalid", agent_name)
    return
  end

  -- ⭐ 恢复 Tab 布局（处理 Chat.new 的副作用）
  self:_restore_tab_layout()

  local agent_winnr = self._tab_info.agent_winnr
  if not agent_winnr or not vim.api.nvim_win_is_valid(agent_winnr) then
    log:warn("[Coordinator] Agent window still invalid after layout restore, cannot switch to %s", agent_name)
    return
  end

  -- 切换右侧窗口的 buffer
  vim.api.nvim_win_set_buf(agent_winnr, agent.chat.bufnr)
  vim.wo[agent_winnr].wrap = true

  -- ⚠️ 不要设置 agent.chat.ui.winnr = agent_winnr
  -- 因为 CC 的 close_last_chat() 会检查 last_chat.ui:is_visible()
  -- 如果 ui.winnr 指向 AGENT 窗口，close_last_chat 会关闭它，破坏布局

  -- 移动光标到 buffer 末尾
  local line_count = vim.api.nvim_buf_line_count(agent.chat.bufnr)
  pcall(vim.api.nvim_win_set_cursor, agent_winnr, { line_count, 0 })

  log:debug("[Coordinator] Switched agent window to %s (bufnr=%d)", agent_name, agent.chat.bufnr)
end

--- 关闭 Multi-Agent Tab 并切回父 Tab
--- Multi-Agent tab 关闭实现
function Coordinator:_close_multi_agent_tab()
  if not self._tab_info then
    return
  end

  -- 先切回父 Tab
  if self._tab_info.parent_tabnr and vim.api.nvim_tabpage_is_valid(self._tab_info.parent_tabnr) then
    vim.api.nvim_set_current_tabpage(self._tab_info.parent_tabnr)
  end

  -- 关闭 Multi-Agent Tab
  if self._tab_info.tabnr and vim.api.nvim_tabpage_is_valid(self._tab_info.tabnr) then
    local tab_list = vim.api.nvim_list_tabpages()
    if #tab_list > 1 then
      for i, tp in ipairs(tab_list) do
        if tp == self._tab_info.tabnr then
          pcall(vim.cmd, "tabclose " .. i)
          break
        end
      end
    else
      -- 只剩一个 Tab，不能关闭，改为关闭其中的窗口
      local wins = vim.api.nvim_tabpage_list_wins(self._tab_info.tabnr)
      for _, winnr in ipairs(wins) do
        if vim.api.nvim_win_is_valid(winnr) then
          pcall(vim.api.nvim_win_close, winnr, true)
        end
      end
    end
  end

  -- 清理 scratch buffer
  if self._tab_info.scratch_bufnr and vim.api.nvim_buf_is_valid(self._tab_info.scratch_bufnr) then
    pcall(vim.api.nvim_buf_delete, self._tab_info.scratch_bufnr, { force = true })
  end

  self._tab_info = nil
  log:debug("[Coordinator] Multi-Agent tab closed")
end

--- 注册事件处理器
---@param event string 事件名称
---@param handler function 处理函数
function Coordinator:on(event, handler)
  if not self._handlers[event] then
    self._handlers[event] = {}
  end
  table.insert(self._handlers[event], handler)
end

--- 发送事件
---@param event string 事件名称
---@param data any 事件数据
function Coordinator:emit(event, data)
  local handlers = self._handlers[event]
  if not handlers then
    return
  end

  for _, handler in ipairs(handlers) do
    handler(data)
  end
end

--- 获取所有 Agent 名称列表
---@return string[]
function Coordinator:get_agent_names()
  local names = {}
  for _, config in ipairs(self.agent_configs) do
    table.insert(names, config.name)
  end
  return names
end

--- 启动讨论
---@param task string 讨论任务
function Coordinator:start(task)
  self.is_running = true
  self.is_finished = false
  self.task = task
  self.round = 1

  -- 创建 Display Chat（延迟创建，此时 _parent_window_manager 已设置）
  if not self.display_chat then
    self:_create_display_chat()
    -- 恢复父窗口（Chat.new 的 close_last_chat 可能隐藏了它）
    if self._parent_window_manager then
      self._parent_window_manager:restore_parent_window()
    end
  end

  -- 创建会话元数据
  self._session = SessionManager.create_session({
    agents = self.agent_configs,
    termination = self.termination,
    shared_background = self._shared_background,
    task = self.task,
    final_agent = self._final_agent,
    final_prompt = self._final_prompt,
    final_max_turns = self._final_max_turns == math.huge and 0 or self._final_max_turns,
    final_agent_config = self._final_agent_config,
    title = self.title,
  })
  self.session_id = self._session.id

  -- 更新会话状态
  SessionManager.update_state(self._session, {
    round = self.round,
    is_finished = false,
  })

  -- 保存初始会话
  local ok, err = SessionManager.save(self._session)
  if not ok then
    log:warn("[Coordinator] Failed to save initial session: %s", err)
  end

  -- 更新 Display Chat 显示任务信息
  -- 需要同时添加到 messages 数组（用于保存历史）和 buffer（用于显示）
  if self.display_chat then
    -- 构建 Agent 列表
    local agent_list = {}
    for _, config in ipairs(self.agent_configs) do
      table.insert(agent_list, string.format("- %s %s: %s", config.icon or "🤖", config.name, config.role))
    end

    local intro_content = string.format(
      "# Multi-Agent Discussion\n\n**Task**: %s\n\n**Agents**:\n%s\n\n---\n",
      task,
      table.concat(agent_list, "\n")
    )

    -- 1. 添加到 messages 数组（用于保存历史）
    if self.display_chat.messages then
      table.insert(self.display_chat.messages, {
        role = "user",
        content = intro_content,
      })
    end

    -- 2. 添加到 buffer（用于显示）
    self.display_chat:add_buf_message({
      role = "user",
      content = intro_content,
    })
  end

  -- 确定初始 Agent
  local first_agent = self.initial_agent
  if not first_agent and #self.agent_configs > 0 then
    first_agent = self.agent_configs[1].name
  end

  -- 运行首个 Agent
  self:_run_agent(first_agent)
end

--- 运行指定 Agent
---@param agent_name string Agent 名称
function Coordinator:_run_agent(agent_name)
  self.current_agent = agent_name

  -- 获取或创建 Agent
  local agent = self.agents[agent_name]
  if not agent then
    agent = self:_create_agent(agent_name)
    if not agent then
      self:_finish("agent_creation_failed")
      return
    end
    self.agents[agent_name] = agent
  end

  -- 恢复父窗口（Chat.new 的 close_last_chat 可能隐藏了它）
  -- 注意：在新 Tab 中运行时跳过，避免在新 Tab 中打开父 Chat 窗口
  if self._parent_window_manager and not self._tab_info then
    self._parent_window_manager:restore_parent_window()
  end

  -- ⭐ 在 Display Chat 中注入"⏳ 思考中..."指示器
  if self.display_chat and self.display_adapter then
    local display_adapter = require("maxa.mcphub.native_servers.subagent.tools.multi_agent.display_adapter")
    local agent_config = self:_get_agent_config(agent_name)
    local icon = agent_config and agent_config.icon or "🤖"
    local role_desc = agent_config and agent_config.role or nil
    display_adapter.inject_thinking(self.display_chat, agent_name, icon, role_desc)
  end

  -- ⭐ 切换右侧窗口到当前 AgentChat（延迟执行，确保 AgentChat 的 Chat 已创建）
  -- 注意：submit 会触发 _ensure_chat()，此时才创建 Chat
  -- 所以先 submit，然后在回调之前切换窗口

  -- 构建上下文消息
  local prompt = self:_build_round_prompt(agent_name)

  -- 更新会话状态
  if self._session then
    SessionManager.update_state(self._session, {
      current_agent = agent_name,
    })

    -- 记录 Agent 的 save_id（如果有）
    local save_id = agent:get_save_id()
    if save_id then
      SessionManager.add_agent_save_id(self._session, agent_name, save_id)
    end

    -- 保存会话
    SessionManager.save(self._session)
  end

  -- 发送消息
  local config = self:_get_agent_config(agent_name)
  agent:submit(prompt, function(response, error, handoff_result)
    self:_on_agent_response(agent_name, response, error, handoff_result)
  end, config.goal_prompt or self.task)

  -- ⭐ submit 后立即切换右侧窗口（此时 AgentChat 的 Chat 已创建）
  vim.schedule(function()
    self:_switch_agent_window(agent_name)
  end)
end

--- 创建 Agent 实例
---@param name string Agent 名称
---@return table|nil AgentChat 实例
function Coordinator:_create_agent(name)
  -- 查找配置
  local config = nil
  for _, cfg in ipairs(self.agent_configs) do
    if cfg.name == name then
      config = cfg
      break
    end
  end

  if not config then
    return nil
  end

  -- 延迟加载 AgentChat 模块
  local ok, AgentChat = pcall(require, "maxa.mcphub.native_servers.subagent.tools.multi_agent.agent_chat")
  if not ok then
    return nil
  end

  local parent = self._parent_chat
  local buffer_context = vim.deepcopy(parent and parent.buffer_context or {})
  local parent_opts = parent and parent.opts or {}
  buffer_context.cwd = parent_opts.cwd or buffer_context.cwd
  buffer_context.project_root = parent_opts.project_root or buffer_context.project_root
  -- 创建 AgentChat 实例
  -- adapter 为 nil 时继承父 Chat 的 adapter
  return AgentChat.new({
    name = config.name,
    role = config.role,
    soul = config.soul,
    soul_prompt = config.soul_prompt,
    soul_file = config.soul_file,
    goal_prompt = config.goal_prompt,
    shared_background = self._shared_background,
    adapter = config.adapter, -- LLM adapter 预设（nil 表示继承父代理）
    parent_adapter = self._parent_adapter, -- 父代理的 adapter（用于继承）
    buffer_context = buffer_context,
    icon = config.icon,
    coordinator = self,
    agent_names = self:get_agent_names(),
    min_rounds = self.termination.minTurns,
    restrict_tools = config.restrict_tools, -- 限定工具列表（除 handoff 外）
    recursion_depth = self._recursion_depth,
    parent_chat = self._parent_chat,
  })
end

--- 处理 Agent 响应
---@param agent_name string Agent 名称
---@param response string|nil 响应内容
---@param error string|nil 错误信息
---@param handoff_result table|nil Handoff 结果
function Coordinator:_on_agent_response(agent_name, response, error, handoff_result)
  if error then
    -- 错误处理：只向 MCP 调用方报告一次，避免随后 _finish 再触发重复响应
    if self.on_error and not self._error_reported then
      self._error_reported = true
      self.on_error(error)
    end
    self:_finish("error:" .. tostring(error))
    return
  end

  -- 如果有 Handoff 结果，直接调用 _on_handoff 处理
  -- 注意：现在使用 HTTP 直接调用，不再通过 MCP 工具的 emit 机制
  if handoff_result then
    -- 重置重试计数（成功调用了 handoff）
    local agent = self.agents[agent_name]
    if agent then
      agent._handoff_retry_count = 0
    end

    -- 构建 handoff 事件并处理
    -- 提取 Agent 的纯文本输出作为公开发言
    local public_speech = response or handoff_result.message
    self:_on_handoff({
      from = agent_name,
      to = handoff_result.target,
      message = handoff_result.message, -- 私信
      public_speech = public_speech, -- 公开发言
    })
  else
    -- Agent 没有调用 Handoff，尝试重试或强制继续
    self:_handle_missing_handoff(agent_name, response)
  end
end

--- 处理 Agent 未调用 Handoff 的情况
--- 方案 A + B: 先自动重试一次，如果仍然失败则强制提取响应继续讨论
---@param agent_name string Agent 名称
---@param response string|nil Agent 的文字响应
function Coordinator:_handle_missing_handoff(agent_name, response)
  local agent = self.agents[agent_name]
  if not agent then
    log:error("[Coordinator] Agent %s not found, cannot handle missing handoff", agent_name)
    self:_finish("agent_not_found")
    return
  end

  -- 获取当前重试次数
  local retry_count = agent._handoff_retry_count or 0

  log:warn(
    "[Coordinator] Agent %s did not call handoff (retry_count=%d), response=%s",
    agent_name,
    retry_count,
    response and string.sub(response, 1, 100) or "nil"
  )

  if retry_count < 1 then
    -- 方案 A: 自动重试 - 发送提醒消息让 Agent 调用 handoff
    agent._handoff_retry_count = retry_count + 1

    local reminder = [[Required action: publish your conclusion as plain text, then call `subagent__handoff`.

This is a new request, so restate your public conclusion before the tool call:
- `target`: next Agent name, or "user" when the minimum contribution count is met
- `message`: concise private note for target; do not put the public conclusion only here

Do not perform new investigation or repeat completed work. Follow the current goal below and complete the public-text-before-handoff sequence.]]

    log:debug("[Coordinator] Sending handoff reminder to agent %s", agent_name)

    -- 注入提醒到 Display Chat
    if self.display_chat and self.display_adapter then
      local display_adapter = require("maxa.mcphub.native_servers.subagent.tools.multi_agent.display_adapter")
      display_adapter.inject_message(
        self.display_chat,
        "System",
        "⚠️",
        self.round,
        string.format("Agent %s 未调用 handoff，正在重试...", agent_name),
        "系统提醒"
      )
    end

    -- 重新提交，让 Agent 调用 handoff
    local config = self:_get_agent_config(agent_name)
    agent:submit(reminder, function(resp, err, result)
      self:_on_agent_response(agent_name, resp, err, result)
    end, config.goal_prompt or self.task)
  else
    -- 方案 B: 重试失败，强制提取响应并继续
    log:warn("[Coordinator] Agent %s retry failed, forcing handoff with extracted response", agent_name)
    self:_force_handoff(agent_name, response)
  end
end

--- 强制 Handoff: 将 Agent 的文字响应作为 message，继续到下一个 Agent
---@param agent_name string 当前 Agent 名称
---@param response string|nil Agent 的文字响应
function Coordinator:_force_handoff(agent_name, response)
  -- 确定下一个 Agent（轮询到下一个，或结束讨论）
  local next_agent = self:_get_next_agent(agent_name)

  -- 构造 message
  local message = response
  if not message or message == "" then
    message = string.format("(Agent %s 未提供有效响应)", agent_name)
  end

  -- 注入提醒到 Display Chat
  if self.display_chat and self.display_adapter then
    local display_adapter = require("maxa.mcphub.native_servers.subagent.tools.multi_agent.display_adapter")
    display_adapter.inject_message(
      self.display_chat,
      "System",
      "⚡",
      self.round,
      string.format("Agent %s 未调用 handoff，系统强制提取响应并继续", agent_name),
      "系统干预"
    )
  end

  log:warn("[Coordinator] Force handoff: %s -> %s", agent_name, next_agent or "user")

  -- 触发 handoff 事件
  -- 强制 handoff 时，response 就是公开发言（因为 Agent 没有正常调用 handoff）
  self:_on_handoff({
    from = agent_name,
    to = next_agent or "user",
    message = "", -- 无私信
    public_speech = message, -- response 作为公开发言
  })
end

--- 获取下一个 Agent（轮询顺序）
---@param current_agent string 当前 Agent 名称
---@return string|nil next_agent 下一个 Agent 名称，如果没有则返回 nil（表示结束）
function Coordinator:_get_next_agent(current_agent)
  local agent_names = self:get_agent_names()
  local count = #agent_names

  if count == 0 then
    return nil
  end

  -- 查找当前 Agent 的索引
  local current_index = nil
  for i, name in ipairs(agent_names) do
    if name == current_agent then
      current_index = i
      break
    end
  end

  if not current_index then
    -- 当前 Agent 不在列表中，返回第一个
    return agent_names[1]
  end

  -- 计算下一个索引（循环）
  local next_index = (current_index % count) + 1

  -- 如果回到第一个 Agent，检查是否应该结束讨论
  -- 这里简单返回下一个，让 _on_handoff 中的 maxTurns 检查来决定是否结束
  return agent_names[next_index]
end

--- 处理 Handoff 事件
--- 任务 10.3: 修改为使用 _sequence 检查 maxTurns
---@param event table Handoff 事件 {from: string, to: string, message: string}
function Coordinator:_on_handoff(event)
  local from = event.from
  local to = event.to
  local private_message = event.message -- 私信（仅 target 可见）
  local public_speech = event.public_speech or event.message -- 公开发言（所有 Agent 可见）

  -- 任务 10.3: 递增 _sequence（发言计数）
  self._sequence = self._sequence + 1

  -- ⭐ 存储公开发言到 discussion_store（所有 Agent 可见）
  self.discussion_store:add_entry(from, public_speech)

  -- 添加到会话元数据（保存公开发言）
  if self._session then
    SessionManager.add_discussion(self._session, {
      agent = from,
      round = self.round,
      message = public_speech,
    })
  end

  -- 注入到 Display Chat (如果存在)
  if self.display_chat and self.display_adapter then
    local display_adapter = require("maxa.mcphub.native_servers.subagent.tools.multi_agent.display_adapter")

    -- The public transcript is also Phase 2 input. Private routing notes belong
    -- only to the recipient's prompt/tool result, never this shared history.
    local display_content = public_speech

    -- ⭐ 先尝试替换"⏳ 思考中..."为最终结果
    local replaced = display_adapter.replace_thinking(self.display_chat, display_content)
    if replaced then
      -- 替换成功，只需添加到 messages（history 保存）
      local config = self:_get_agent_config(from)
      local icon = config and config.icon or "🤖"
      local role_desc = config and config.role or nil
      local display_name = from
      if role_desc and role_desc ~= "" then
        display_name = from .. " (" .. role_desc .. ")"
      end
      local formatted_content =
        string.format("\n## %s %s\n\n%s\n\n---\n", icon or "🤖", display_name, display_content)
      if self.display_chat.messages then
        table.insert(self.display_chat.messages, {
          role = "assistant",
          content = formatted_content,
        })
      end
    else
      -- Fallback: 没有思考中指示器，使用原来的一次性注入
      local config = self:_get_agent_config(from)
      local icon = config and config.icon or "🤖"
      local role_desc = config and config.role or nil
      display_adapter.inject_message(self.display_chat, from, icon, self.round, display_content, role_desc)
    end
  end

  -- 检查是否结束
  if to == "user" then
    self:_finish("handoff_to_user")
    return
  end

  -- 任务 10.3: 检查 maxTurns 限制（使用 _sequence）
  if self._sequence >= self.termination.maxTurns then
    self:_finish("max_turns_reached")
    return
  end

  -- 检查是否需要增加轮次 (回到第一个 Agent)
  local first_agent = self.agent_configs[1] and self.agent_configs[1].name
  if to == first_agent and from ~= first_agent then
    self.round = self.round + 1

    -- 更新会话轮次
    if self._session then
      SessionManager.update_state(self._session, {
        round = self.round,
      })
    end
  end

  -- 检查其他终止条件（max_messages 等）
  local should_stop, reason = self:_check_termination()
  if should_stop then
    self:_finish(reason)
    return
  end

  -- ⭐ 检查目标 Agent 是否有 pending handoff（即它在等待结果）
  -- 如果有，应该完成它的工具调用（Resume via Tool Result），而不是发起新的 submit
  local pending = self:_find_pending_handoff(to)
  if pending then
    -- 构建从该 agent 之后的所有讨论记录
    local discussion_after = {}
    if self.discussion_store and self.discussion_store.get_entries_after then
      discussion_after = self.discussion_store:get_entries_after(pending.sequence)
    end
    local last_agent = #discussion_after > 0 and discussion_after[#discussion_after].agent or nil

    -- 构建返回结果
    local result = {
      status = "handoff_completed",
      discussion_after = discussion_after,
      last_agent = last_agent,
    }

    -- Include private message only when it differs from public speech.
    if private_message and private_message ~= public_speech then
      result.private_message_from = from
      result.private_message = private_message
    end

    -- 从 pending 队列中移除
    self:_remove_pending_handoff(to)

    -- 重置目标 Agent 的等待状态
    local target_agent = self.agents[to]
    if target_agent then
      target_agent._waiting_for_handoff = false

      -- ⭐ 重新设置 MCP handoff 上下文为目标 Agent
      -- 这样当目标 Agent 继续运行并调用 handoff 时，context 是正确的
      local mcp_handoff = require("maxa.mcphub.native_servers.subagent.tools.multi_agent.mcp_handoff")
      mcp_handoff.set_active_context({
        coordinator = self,
        agent_name = to,
        agent_names = self:get_agent_names(),
        agent = target_agent,
      })
    end

    -- ⭐ 注入"⏳ 思考中..."到 Display Chat（Resume 时 Agent 会继续响应）
    if self.display_chat and self.display_adapter then
      local display_adapter = require("maxa.mcphub.native_servers.subagent.tools.multi_agent.display_adapter")
      local agent_config = self:_get_agent_config(to)
      local icon = agent_config and agent_config.icon or "🤖"
      local role_desc = agent_config and agent_config.role or nil
      display_adapter.inject_thinking(self.display_chat, to, icon, role_desc)
    end

    -- ⭐ 切换右侧窗口到 Resume 的 Agent
    self:_switch_agent_window(to)

    -- 调用 MCP response 返回，让目标 Agent 的 LLM 继续处理
    log:debug("[Coordinator] Resuming Agent %s via tool result", to)
    pending.res:text(require("maxa.mcphub.native_servers.subagent.result_format").handoff(result)):send()
  else
    -- ⭐ 存储私信，供 _build_round_prompt 使用
    if private_message and private_message ~= public_speech then
      self._pending_private_messages = self._pending_private_messages or {}
      self._pending_private_messages[to] = {
        from = from,
        message = private_message,
      }
    end
    -- 目标 Agent 没有 pending handoff，发起新的 submit
    self:_run_agent(to)
  end
end

--- 查找指定 Agent 的 pending handoff
---@param agent_name string Agent 名称
---@return table|nil pending handoff 记录
function Coordinator:_find_pending_handoff(agent_name)
  for _, pending in ipairs(self._pending_handoffs) do
    if pending.agent_name == agent_name then
      return pending
    end
  end
  return nil
end

--- 从 pending 队列中移除指定 Agent 的 handoff
---@param agent_name string Agent 名称
function Coordinator:_remove_pending_handoff(agent_name)
  for i, pending in ipairs(self._pending_handoffs) do
    if pending.agent_name == agent_name then
      table.remove(self._pending_handoffs, i)
      return
    end
  end
end

--- 构建每轮的 user 消息
--- 包含轮次信息、其他 Agent 的讨论记录和任务描述
---@param agent_name string 当前 Agent 名称
---@return string 格式化的 user 消息
function Coordinator:_build_round_prompt(agent_name)
  local parts = {}

  -- 轮次标记
  table.insert(parts, string.format("[ROUND %d]", self.round))
  table.insert(parts, "")

  -- 其他 Agent 的讨论记录
  table.insert(parts, "## Other Agents' Messages")
  local entries = self.discussion_store:get_entries_for_agent(agent_name)

  if #entries == 0 then
    table.insert(parts, "(No messages from other agents yet)")
  else
    for _, entry in ipairs(entries) do
      table.insert(parts, string.format("- %s: %s", entry.agent, entry.message))
    end
  end

  table.insert(parts, "")

  -- ⭐ 私信部分（仅发给当前 Agent 的私信）
  if self._pending_private_messages and self._pending_private_messages[agent_name] then
    local pm = self._pending_private_messages[agent_name]
    table.insert(parts, "## Private Message")
    table.insert(parts, string.format("📩 From %s (only you can see this): %s", pm.from, pm.message))
    table.insert(parts, "")
    -- 消费后清除
    self._pending_private_messages[agent_name] = nil
  end

  table.insert(parts, "## Shared Discussion Task")
  table.insert(parts, self.task)

  return table.concat(parts, "\n")
end

--- 获取 Agent 配置
---@param name string Agent 名称
---@return table|nil 配置
function Coordinator:_get_agent_config(name)
  for _, config in ipairs(self.agent_configs) do
    if config.name == name then
      return config
    end
  end
  return nil
end

--- 检查终止条件
---@return boolean should_stop 是否应该停止
---@return string|nil reason 停止原因
function Coordinator:_check_termination()
  -- 检查轮数限制
  if self.termination.maxTurns and self.round >= self.termination.maxTurns then
    return true, "max_turns"
  end

  -- 检查消息数限制
  if self.termination.max_messages then
    local total = self.discussion_store:get_entry_count()
    if total >= self.termination.max_messages then
      return true, "max_messages"
    end
  end

  return false, nil
end

--- 从 MaxaAI 的 chatmap 中移除所有相关 chat
--- 防止用户打开 history 时遇到无效 buffer
--- 注意：不再调用 chat:close()（会立即删除 buffer），改为手动清理
function Coordinator:_remove_from_chatmap()
  -- ⭐ 如果在 Phase 2 中，跳过清理（Phase 2 完成后会再次调用）
  if self._in_phase2 and not self._phase2_completed then
    log:debug("[Coordinator] Skipping _remove_from_chatmap during Phase 2")
    return
  end

  -- ⭐ 检查 chat 状态，如果还在 running 则延迟重试
  for name, agent in pairs(self.agents) do
    if agent and agent.chat and agent.chat.status == "running" then
      log:debug("[Coordinator] Agent %s still running, delay cleanup by 1000ms", name)
      vim.defer_fn(function()
        self:_remove_from_chatmap()
      end, 1000)
      return
    end
  end

  local chat_module_ok, chat_module = pcall(require, "maxa.interactions.chat")
  if not chat_module_ok then
    return
  end

  -- 先保存 Display Chat 到 history（在删除 buffer 之前）
  if self.display_chat then
    self:_save_display_chat_to_history()
  end

  -- 收集需要移除的 bufnr
  local bufnrs_to_remove = {}

  -- Display Chat
  if self.display_chat and self.display_chat.bufnr then
    bufnrs_to_remove[self.display_chat.bufnr] = "display_chat"
  end

  -- 所有 Agent Chat
  for name, agent in pairs(self.agents) do
    if agent and agent.chat and agent.chat.bufnr then
      bufnrs_to_remove[agent.chat.bufnr] = "agent:" .. name
    end
  end

  -- ⭐ 只隐藏窗口，不删除 buffer
  -- buffer 删除由 cleanup() 方法在更长延迟后处理，确保 HTTP 响应完全结束

  -- 辅助函数：隐藏单个 chat 的窗口
  local function hide_chat_window(chat, chat_type)
    if not chat then
      return
    end

    -- 隐藏窗口（不删除 buffer）
    if chat.ui and chat.ui.winnr and vim.api.nvim_win_is_valid(chat.ui.winnr) then
      pcall(vim.api.nvim_win_hide, chat.ui.winnr)
      log:debug("[Coordinator] Hidden chat window, type=%s, winnr=%d", chat_type, chat.ui.winnr)
    end

    -- 也检查 coordinator 保存的 display_winnr
    if chat_type == "display_chat" and self._display_winnr and vim.api.nvim_win_is_valid(self._display_winnr) then
      pcall(vim.api.nvim_win_hide, self._display_winnr)
      self._display_winnr = nil
    end
  end

  -- ⭐ 关闭 Multi-Agent Tab 并切回父 Tab
  self:_close_multi_agent_tab()

  -- ⭐ 恢复父 Chat 窗口（close_last_chat 可能在讨论过程中隐藏了它）
  if self._parent_window_manager then
    self._parent_window_manager:restore_parent_window()
  end

  -- 隐藏 Display Chat 窗口（Tab 关闭后可能还残留）
  if self.display_chat then
    hide_chat_window(self.display_chat, "display_chat")
  end

  -- 隐藏所有 Agent Chat 窗口（Tab 关闭后可能还残留）
  for name, agent in pairs(self.agents) do
    if agent and agent.chat then
      hide_chat_window(agent.chat, "agent:" .. name)
    end
  end

  -- 注意：不在这里删除 buffer，也不清空引用
  -- buffer 删除由 cleanup() 方法处理
end

--- 结束讨论
--- Phase 1 结束时，如果有 Phase 2 配置，则启动 Phase 2
--- Phase 2 结束时，执行真正的清理逻辑
---@param reason string 结束原因
function Coordinator:_finish(reason)
  log:debug("[Coordinator] _finish called, reason=%s, _in_phase2=%s", reason, tostring(self._in_phase2))

  -- Phase 1 结束，检查是否需要启动 Phase 2
  if not self._error_reported and not self._in_phase2 and self._final_agent and self._final_prompt then
    log:debug("[Coordinator] Phase 1 finished, starting Phase 2 with final_agent=%s", self._final_agent)
    local ok, err = xpcall(function() self:_start_phase2() end, debug.traceback)
    if not ok then self:_on_phase2_complete("error:" .. tostring(err)) end
    return
  end

  -- Phase 2 结束或无 Phase 2 配置，执行真正的结束逻辑
  -- ⭐ 立即设置 finishing 标记，阻止后续操作（如 AgentChat 的 on_completed 回调）
  self._is_finishing = true

  log:debug("[Coordinator] Final finish, reason=%s, _is_finishing=true", reason)

  self.is_running = false
  self.is_finished = true
  self._finish_reason = reason

  -- ⭐ 立即停止所有 Agent 的 HTTP 请求并清除 autocmd
  -- 这是关键！必须在发送 MCP 返回之前清除 autocmd，防止 MaxaAIToolsFinished 事件触发回调
  for name, agent in pairs(self.agents) do
    if agent and agent.chat then
      local chat = agent.chat
      -- 设置打断标志
      chat._subagent_interrupted = true

      -- ⭐ 立即清除 autocmd（防止 MCP 返回后触发 MaxaAIToolsFinished 等事件）
      if chat.aug then
        pcall(vim.api.nvim_clear_autocmds, { group = chat.aug })
      end
      if chat.tools and chat.tools.aug then
        pcall(vim.api.nvim_clear_autocmds, { group = chat.tools.aug })
      end

      -- 调用 MaxaAI 的 stop() 方法（如果有正在进行的请求）
      if chat.current_request or chat.current_tool then
        pcall(function()
          chat:stop()
        end)
      end
    end
  end

  -- ⭐ 收集需要等待完成的 Agent（在发送 handoff 返回之前）
  self._pending_completion_agents = {}
  for _, pending in ipairs(self._pending_handoffs) do
    self._pending_completion_agents[pending.agent_name] = true
  end

  log:debug("[Coordinator] _pending_handoffs count=%d", #self._pending_handoffs)

  -- ⭐ 在 resolve 之前关闭 Tab 并恢复父窗口
  -- 原因：resolve 触发父 Chat 回调 → submit → close_last_chat → 关闭 Display Chat 窗口 → Tab 消失
  -- 提前关闭 Tab 可以避免这个竞争条件
  self:_close_multi_agent_tab()

  -- ⭐ 立即恢复父 Chat 窗口
  -- 原因：on_complete → res:send() → add_tool_output → tool_display hook 中的 vim.schedule
  -- 回调需要 buffer 有窗口才能创建折叠（fold 命令是窗口级操作）
  if self._parent_window_manager then
    self._parent_window_manager:restore_parent_window()
  end

  -- 任务 10.1: 解析所有等待中的 handoff（发送返回结果）
  -- ⚠️ 必须在 _remove_from_chatmap 之前执行，因为 MCP 回调会触发 add_tool_output
  self:resolve_all_pending_handoffs()

  -- ⭐ 延迟从 MaxaAI 的 chatmap 中移除所有相关 chat
  -- 必须在 resolve_all_pending_handoffs 之后执行，给 MCP 回调足够时间完成
  vim.defer_fn(function()
    self:_remove_from_chatmap()
  end, 2000)

  -- ⭐ 新方案：不再等待 Agent 完成响应，直接延迟清理
  -- 因为 LLM 可能会再次调用工具，导致 on_completed 永远不会被触发
  -- 我们给 LLM 足够的时间完成响应（10秒），然后强制清理
  vim.defer_fn(function()
    self:cleanup()
  end, 10000)

  -- 更新会话状态
  if self._session then
    SessionManager.update_state(self._session, {
      is_finished = true,
    })

    -- 保存最终会话
    local ok, err = SessionManager.save(self._session)
    if not ok then
      log:warn("[Coordinator] Failed to save final session: %s", err)
    end
  end

  -- 构建结果
  local result = {
    id = self.session_id,
    discussions = self.discussion_store:get_all_entries(),
    is_finished = true,
    stats = {
      rounds = self.round,
      total_messages = self.discussion_store:get_entry_count(),
      finish_reason = reason,
    },
  }

  -- 调用完成回调；错误已通过 on_error 返回时，避免重复发送 MCP response
  if self.on_complete and not self._error_reported then
    self.on_complete(result)
  end

  -- ⭐ 新方案：不立即 cleanup，而是等待所有 Agent 完成响应后再清理
  -- 设置完成监听器
  self:_setup_completion_listeners()
end

--- 设置完成监听器，等待所有 Agent 完成响应后再清理
function Coordinator:_setup_completion_listeners()
  -- 如果没有需要等待的 Agent，直接清理
  if not self._pending_completion_agents or vim.tbl_isempty(self._pending_completion_agents) then
    log:debug("[Coordinator] No pending agents, cleanup immediately")
    self:_delayed_cleanup()
    return
  end

  log:debug("[Coordinator] Waiting for %d agents to complete", vim.tbl_count(self._pending_completion_agents))

  -- 为每个需要等待的 Agent 设置完成监听器
  local self_ref = self
  for agent_name, _ in pairs(self._pending_completion_agents) do
    local agent = self.agents[agent_name]
    if agent then
      -- 使用 _on_session_finished 回调，这会在 _on_chat_completed 中被触发
      agent._on_session_finished = function()
        self_ref:_on_agent_finished(agent_name)
      end

      log:debug("[Coordinator] Setup completion listener for agent: %s", agent_name)
    else
      -- Agent 不存在，直接标记完成
      self:_on_agent_finished(agent_name)
    end
  end

  -- 设置超时保护，防止 Agent 永远不完成
  -- 由于 _is_finishing 检查，Agent 应该能快速完成，所以缩短超时时间
  vim.defer_fn(function()
    if self_ref._pending_completion_agents and not vim.tbl_isempty(self_ref._pending_completion_agents) then
      log:debug("[Coordinator] Timeout waiting for agents, force cleanup")
      self_ref._pending_completion_agents = {}
      self_ref:_delayed_cleanup()
    end
  end, 8000) -- 8 秒超时（从 30 秒缩短）
end

--- Agent 完成响应后的回调
---@param agent_name string Agent 名称
function Coordinator:_on_agent_finished(agent_name)
  if not self._pending_completion_agents then
    return
  end

  -- 移除已完成的 Agent
  self._pending_completion_agents[agent_name] = nil
  log:debug(
    "[Coordinator] Agent %s finished, remaining: %d",
    agent_name,
    vim.tbl_count(self._pending_completion_agents)
  )

  -- 如果所有 Agent 都完成了，执行清理
  if vim.tbl_isempty(self._pending_completion_agents) then
    log:debug("[Coordinator] All agents finished, starting cleanup")
    self:_delayed_cleanup()
  end
end

--- 延迟清理，给 UI 更新留出时间
function Coordinator:_delayed_cleanup()
  vim.defer_fn(function()
    self:cleanup()
  end, 500)
end

--- 暂停当前 Agent 执行
--- 复用 window_manager 的打断机制
function Coordinator:pause()
  if self.is_paused then
    return
  end

  self.is_paused = true

  -- 如果没有在运行，只设置暂停状态
  if not self.is_running then
    return
  end

  -- 获取当前 Agent
  local agent = self.agents[self.current_agent]
  if not agent then
    return
  end

  -- 复用 window_manager 的打断逻辑
  local chat = agent.chat
  if chat then
    -- 设置打断标志
    chat._subagent_interrupted = true

    -- 重置状态为 idle
    chat.status = "idle"

    -- 取消 HTTP 请求
    local handle = chat.current_request
    if handle then
      chat.current_request = nil
      pcall(function()
        if type(handle.cancel) == "function" then
          handle.cancel()
        end
      end)
    end

    -- 调用 adapter 的 on_exit handler
    local ok_adapters, adapters = pcall(require, "maxa.adapters")
    if ok_adapters then
      adapters.call_handler(chat.adapter, "on_exit")
    end
  end

  -- 设置 agent 为非忙碌状态
  if agent.is_busy ~= nil then
    agent.is_busy = false
  end

  log:debug("[Coordinator] Paused at agent: %s, round: %d", self.current_agent, self.round)
end

--- 插入用户消息并继续执行
---@param message string 用户干预消息
function Coordinator:resume_with_message(message)
  if not self.is_paused then
    return
  end

  -- 添加用户干预消息到 discussion_store
  self.discussion_store:add_entry("user", message)

  -- 添加到会话元数据
  if self._session then
    SessionManager.add_discussion(self._session, {
      agent = "user",
      round = self.round,
      message = message,
      is_intervention = true,
    })
  end

  -- 注入到 Display Chat (如果存在)
  if self.display_chat and self.display_adapter then
    local display_adapter = require("maxa.mcphub.native_servers.subagent.tools.multi_agent.display_adapter")
    display_adapter.inject_message(self.display_chat, "User", "👤", self.round, message, "用户干预")
  end

  -- 重置暂停状态
  self.is_paused = false

  -- 重置当前 Agent 的打断标志
  local agent = self.agents[self.current_agent]
  if agent and agent.chat then
    agent.chat._subagent_interrupted = false
  end

  -- 发送 handoff 事件继续执行（用户消息后继续当前 Agent）
  self:emit("handoff", {
    from = "user",
    to = self.current_agent,
    message = message,
  })

  log:debug("[Coordinator] Resumed with user message, continuing to agent: %s", self.current_agent)
end

--- 设置用户干预键位映射
--- 在指定 buffer 上设置 Ctrl+C (暂停) 和 Ctrl+S (继续) 键位
---@param bufnr number Buffer 编号
---@param get_user_input? function 获取用户输入的函数，返回 string 或 nil
function Coordinator:setup_intervention_keymaps(bufnr, get_user_input)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  local self_ref = self
  local opts = { buffer = bufnr, nowait = true, silent = true }

  -- Ctrl+C: 暂停当前 Agent
  vim.keymap.set("n", "<C-c>", function()
    self_ref:pause()
    vim.notify("[MultiAgent] Paused. Press Ctrl+S to continue with a message.", vim.log.levels.INFO)
  end, vim.tbl_extend("force", opts, { desc = "Pause multi-agent discussion" }))

  vim.keymap.set("i", "<C-c>", function()
    self_ref:pause()
    vim.notify("[MultiAgent] Paused. Press Ctrl+S to continue with a message.", vim.log.levels.INFO)
  end, vim.tbl_extend("force", opts, { desc = "Pause multi-agent discussion" }))

  -- Ctrl+S: 获取用户输入并继续
  vim.keymap.set("n", "<C-s>", function()
    if not self_ref.is_paused then
      vim.notify("[MultiAgent] Not paused. Press Ctrl+C first to pause.", vim.log.levels.WARN)
      return
    end

    -- 获取用户输入
    local input_fn = get_user_input or function()
      return vim.fn.input("Enter message: ")
    end

    local message = input_fn()
    if message and message ~= "" then
      self_ref:resume_with_message(message)
    else
      vim.notify("[MultiAgent] Empty message. Still paused.", vim.log.levels.WARN)
    end
  end, vim.tbl_extend("force", opts, { desc = "Resume multi-agent with user message" }))

  log:debug("[Coordinator] Intervention keymaps set for buffer: %d", bufnr)
end

--- 任务 10.1: 添加等待中的 handoff
---@param agent_name string Agent 名称
---@param res table MCP response 对象
---@param message string 对 target 说的话
function Coordinator:add_pending_handoff(agent_name, res, message)
  table.insert(self._pending_handoffs, {
    agent_name = agent_name,
    res = res,
    message = message,
    sequence = self._sequence, -- 记录当前序号（_sequence 在 _on_handoff 中递增）
  })
  log:debug("[Coordinator] Added pending handoff from %s, sequence=%d", agent_name, self._sequence)
end

--- 任务 10.1: 解析所有等待中的 handoff，按 LIFO 顺序返回
--- 注意：在 _finish 中调用时，Agent 的 HTTP 请求已被 stop()，
--- 所以这里的返回不会触发新的 LLM 响应
function Coordinator:resolve_all_pending_handoffs()
  -- 按 LIFO 顺序处理（后进先出）
  for i = #self._pending_handoffs, 1, -1 do
    local pending = self._pending_handoffs[i]

    -- 构建从该 agent 之后的所有讨论记录
    local discussion_after = {}
    if self.discussion_store and self.discussion_store.get_entries_after then
      discussion_after = self.discussion_store:get_entries_after(pending.sequence)
    end
    local last_agent = #discussion_after > 0 and discussion_after[#discussion_after].agent or nil

    -- 构建返回结果，添加终止指令
    local result = {
      status = "session_ended",
      discussion_after = discussion_after,
      last_agent = last_agent,
      -- ⭐ 明确告诉 LLM 会话已结束，不要继续处理
      message = "The multi-agent discussion has ended. Session cleanup in progress.",
    }

    -- 调用 MCP response 返回
    pending.res:text(require("maxa.mcphub.native_servers.subagent.result_format").handoff(result)):send()
  end

  -- 清空队列
  self._pending_handoffs = {}
end

--- 清理资源
---@param opts? {immediate?: boolean} 选项，immediate=true 时立即删除 buffer
function Coordinator:cleanup(opts)
  opts = opts or {}

  -- ⭐ 如果在 Phase 2 中，跳过清理（Phase 2 完成后会再次调用）
  if self._in_phase2 and not self._phase2_completed then
    log:debug("[Coordinator] Skipping cleanup during Phase 2")
    return
  end

  -- ⭐ 首先停止所有 Agent 的 HTTP 请求，使用 MaxaAI 的 stop() 方法
  for name, agent in pairs(self.agents) do
    if agent then
      -- 重置状态
      agent.is_busy = false
      agent._waiting_for_handoff = false
      agent._on_response = nil

      -- 停止 HTTP 请求
      local chat = agent.chat
      if chat then
        -- 设置打断标志
        chat._subagent_interrupted = true
        -- 调用 MaxaAI 的 stop() 方法（如果有正在进行的请求）
        if chat.current_request or chat.current_tool then
          pcall(function()
            chat:stop()
          end)
        end
      end
    end
  end

  -- 辅助函数：清理单个 chat 的窗口和 buffer
  local function cleanup_chat_resources(chat, chat_type)
    if not chat then
      return
    end

    local bufnr = chat.bufnr

    -- 1. 移除 buffer 保护标记
    if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
      vim.b[bufnr]._multi_agent_protected = nil
      vim.b[bufnr]._maxa_ai = nil
    end

    -- 2. 清除 autocmd（防止 MaxaAIToolsFinished 等事件触发回调访问 buffer）
    -- 这是关键！手动按 q 退出时，Chat:close() 也会清除 autocmd
    if chat.aug then
      pcall(vim.api.nvim_clear_autocmds, { group = chat.aug })
    end
    -- 同时清除 tools 的 autocmd
    if chat.tools and chat.tools.aug then
      pcall(vim.api.nvim_clear_autocmds, { group = chat.tools.aug })
    end

    -- 3. 从 MaxaAI 的 chatmap 中移除（防止退出时访问已删除的 buffer）
    if bufnr then
      pcall(function()
        local Chat = require("maxa.interactions.chat")
        -- 调用 chat:close() 会自动从 chatmap 中移除
        -- 但我们已经手动清理了，所以直接设置 nil
        if chat.close then
          -- 设置标志防止 close() 再次删除 buffer
          chat._closing = true
          pcall(chat.close, chat)
        end
      end)
      log:debug("[Coordinator] Removed chat from chatmap, bufnr=%d", bufnr)
    end

    -- 4. 隐藏窗口
    if chat.ui and chat.ui.winnr and vim.api.nvim_win_is_valid(chat.ui.winnr) then
      pcall(vim.api.nvim_win_hide, chat.ui.winnr)
    end

    -- 5. 也检查 coordinator 保存的 display_winnr
    if chat_type == "display_chat" and self._display_winnr and vim.api.nvim_win_is_valid(self._display_winnr) then
      pcall(vim.api.nvim_win_hide, self._display_winnr)
      self._display_winnr = nil
    end

    -- 6. 延迟删除 buffer（模拟手动按 q 退出的行为）
    if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
      vim.defer_fn(function()
        if vim.api.nvim_buf_is_valid(bufnr) then
          pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
          log:debug("[Coordinator] Deleted buffer %d", bufnr)
        end
      end, 500) -- 500ms 延迟，给 stop() 的 done() 回调时间完成
    end
  end

  -- 清理 Display Chat
  if self.display_chat then
    cleanup_chat_resources(self.display_chat, "display_chat")
  end

  -- 清理所有 Agent Chat
  for name, agent in pairs(self.agents) do
    if agent and agent.chat then
      cleanup_chat_resources(agent.chat, "agent:" .. name)
    end
  end

  -- 延迟清空引用
  local delay = opts.immediate and 0 or 500

  vim.defer_fn(function()
    self.agents = {}
    self.display_chat = nil
  end, delay)
end

--- 保存 Display Chat 到 history
function Coordinator:_save_display_chat_to_history()
  if not self.display_chat then
    log:debug("[Coordinator] No display_chat to save")
    return
  end

  -- 尝试加载 history 插件并获取 exports.save_chat 函数
  local ok, history_ext = pcall(require, "maxa.session.history")
  if not ok or not history_ext then
    log:debug("[Coordinator] History extension not available, skipping save")
    return
  end

  -- 检查 exports.save_chat 是否可用
  local exports = history_ext.exports
  if not exports or not exports.save_chat then
    log:debug("[Coordinator] History exports.save_chat not available, skipping save")
    return
  end

  -- 确保 display_chat 有必要的字段
  local chat = self.display_chat

  -- 确保 opts 存在
  if not chat.opts then
    chat.opts = {}
  end

  -- 生成唯一的 save_id（必须是字符串）
  if not chat.opts.save_id then
    local history_utils = require("maxa.session.history.utils")
    chat.opts.save_id = history_utils.generate_save_id({ prefix = "multi_agent" })
  end

  -- 设置标题（包含任务信息）
  local title = "Multi-Agent: " .. (self.task and self.task:sub(1, 50) or "Discussion")
  if #(self.task or "") > 50 then
    title = title .. "..."
  end
  chat.opts.title = title

  -- 设置 title_refresh_count 为最大值，阻止 history 插件自动刷新标题
  chat.opts.title_refresh_count = 999

  -- 确保 messages 存在（history 插件需要）
  if not chat.messages then
    chat.messages = {}
  end

  -- 确保 adapter 存在
  if not chat.adapter then
    chat.adapter = { name = "multi-agent-display" }
  end

  -- 确保 settings 存在
  if not chat.settings then
    chat.settings = {}
  end

  log:debug(
    "[Coordinator] Saving display chat: save_id=%s, title=%s, messages=%d",
    chat.opts.save_id,
    chat.opts.title,
    #chat.messages
  )

  -- 保存到 history（使用 exports.save_chat）
  local save_ok, save_err = pcall(function()
    exports.save_chat(chat)
  end)

  if save_ok then
    log:debug("[Coordinator] Display chat saved to history successfully: %s", chat.opts.save_id)
    vim.notify(string.format("[Multi-Agent] Discussion saved to history: %s", chat.opts.title), vim.log.levels.INFO)
  else
    log:warn("[Coordinator] Failed to save display chat to history: %s", tostring(save_err))
    vim.notify(string.format("[Multi-Agent] Failed to save to history: %s", tostring(save_err)), vim.log.levels.WARN)
  end
end

--- 从保存的会话恢复 Coordinator
---@param session_id string 会话 ID
---@return MultiAgentCoordinator|nil coordinator 恢复的 Coordinator
---@return string|nil error 错误信息
function Coordinator.restore(session_id)
  -- 加载会话元数据
  local session, err = SessionManager.load(session_id)
  if not session then
    return nil, "Failed to load session: " .. (err or "unknown error")
  end

  -- 检查会话是否已结束
  if session.state and session.state.is_finished then
    return nil, "Session is already finished"
  end

  -- 从配置创建 Coordinator
  local coordinator = Coordinator.new({
    agents = session.config.agents,
    termination = session.config.termination,
    shared_background = session.config.shared_background or {},
    final_agent = session.config.final_agent,
    final_prompt = session.config.final_prompt,
    final_max_turns = session.config.final_max_turns,
    final_agent_config = session.config.final_agent_config,
    title = session.config.title,
  })
  coordinator.task = session.config.task

  -- 恢复状态
  coordinator.session_id = session.id
  coordinator._session = session
  coordinator.round = session.state and session.state.round or 1
  coordinator.current_agent = session.state and session.state.current_agent or nil

  -- 恢复 DiscussionStore
  if session.discussions and #session.discussions > 0 then
    coordinator.discussion_store:restore(session.discussions)
  end

  -- 恢复 Agent 实例（通过 session 获取消息）
  -- 注意：这里只恢复元数据，实际的 Agent Chat 会在 _run_agent 时重新创建
  -- 如果需要完整恢复历史消息，需要调用 session__get_messages

  log:debug("[Coordinator] Restored session: %s (round=%d)", session_id, coordinator.round)

  return coordinator, nil
end

--- 继续已恢复的会话
---@param task? string 可选的新任务（追加到讨论）
function Coordinator:resume(task)
  if not self._session then
    log:error("[Coordinator] Cannot resume: no session loaded")
    return
  end

  self.is_running = true
  self.is_finished = false

  -- 如果有新任务，更新任务
  if task then
    self.task = task
    self._session.config.task = task
  end
  if not self.display_chat then self:_create_display_chat() end

  -- 确定下一个 Agent
  local next_agent = self.current_agent
  if not next_agent then
    -- 如果没有当前 Agent，从第一个开始
    next_agent = self.agent_configs[1] and self.agent_configs[1].name
  end

  -- 运行 Agent
  self:_run_agent(next_agent)
end

-- ============================================================================
-- Phase 2: Display Chat 升级为真实 Agent
-- ============================================================================

--- Phase 2 入口：将 Display Chat 升级为真实 Agent 执行最终任务
--- 在 Phase 1 (多角色讨论) 结束后自动调用
function Coordinator:_start_phase2()
  log:debug("[Coordinator] Starting Phase 2, final_agent=%s", self._final_agent)

  -- 标记进入 Phase 2
  self._in_phase2 = true
  self._phase2_turn = 0

  -- 检查 Display Chat 是否存在
  if not self.display_chat then
    log:error("[Coordinator] Display chat not found, cannot start Phase 2")
    self:_on_phase2_complete("error:Display Chat not found")
    return
  end

  -- 添加 final_prompt 到 Display Chat。
  local final_prompt = self._final_prompt
  if self.display_chat.messages then
    local utils = require("maxa.mcphub.native_servers.subagent.utils")

    local phase2_task = "[PHASE 2 TASK]\n\n" .. final_prompt
    utils.append_sub_agent_tail(self.display_chat.messages, phase2_task)
  end

  -- 同时添加到 buffer 显示（直接操作 buffer，避免 add_buf_message 渲染 "## Me" header）
  if self.display_chat.bufnr and vim.api.nvim_buf_is_valid(self.display_chat.bufnr) then
    if self.display_chat.ui then self.display_chat.ui:unlock_buf() end
    local lines = vim.split("---\n\n## Phase 2: Final Task\n\n" .. final_prompt .. "\n", "\n", { plain = true })
    vim.api.nvim_buf_set_lines(self.display_chat.bufnr, -1, -1, false, lines)
    if self.display_chat.ui then self.display_chat.ui:lock_buf() end
  end

  -- ⭐ Phase 2: 保持右侧 Agent 窗口（避免 Display Chat 突然全屏的布局变动）
  -- 右侧窗口会在 _close_multi_agent_tab 时和 Tab 一起关闭

  -- 根据 final_agent 类型分发
  if self._final_agent == "fork" then
    self:_start_phase2_fork()
  elseif self._final_agent == "run" then
    self:_start_phase2_run()
  else
    log:error("[Coordinator] Unknown final_agent type: %s", tostring(self._final_agent))
    self:_on_phase2_complete("error:Unknown final agent type")
  end
end

--- Install execution state through the Chat-owned adapter/prompt APIs.
function Coordinator:_configure_final_chat(adapter, prompt)
  local chat = self.display_chat
  chat:change_adapter(adapter)
  chat.tools.adapter = chat.adapter
  chat.opts.ignore_system_prompt = false
  chat:set_system_prompt(prompt, { visible = false, index = 1 })
  chat.opts.ignore_system_prompt = true
end

--- Phase 2 Fork 模式：继承父 Chat 的 adapter 和工具
function Coordinator:_start_phase2_fork()
  log:debug("[Coordinator] Phase 2 Fork mode starting")

  local chat = self.display_chat
  if not chat then
    self:_on_phase2_complete("error:Display Chat not found")
    return
  end

  -- 设置 adapter（继承父 Chat）
  if self._parent_adapter then
    local prompt = utils.inherit_system_prompt_from_parent(self._parent_chat)
    if not prompt or prompt == "" then
      prompt = assert(utils.build_soul_system_prompt({}, chat.opts))
    end
    self:_configure_final_chat(vim.deepcopy(self._parent_adapter), prompt)
    log:debug("[Coordinator] Phase 2 Fork: inherited parent adapter and composition")
  else
    log:error("[Coordinator] No parent adapter for fork mode")
    self:_on_phase2_complete("error:No parent adapter for fork mode")
    return
  end

  -- 继承父 Chat 的工具
  local utils = require("maxa.mcphub.native_servers.subagent.utils")
  if self._parent_chat then
    utils.inherit_tool_registry(self._parent_chat, chat)
    log:debug("[Coordinator] Phase 2 Fork: inherited tool registry")

    -- [AbilityHook] 注册 cascade parent_chain（Phase 2 fork 继承父 hook 链）
    local sh_ok, sh_registry = pcall(require, "maxa.abilities.hooks.registry")
    if sh_ok then
      sh_registry.register_parent_chain(self._parent_chat.id, chat.id)
    end
  end

  -- 设置 auto_submit 相关配置（非交互模式）
  chat.opts = chat.opts or {}
  chat.opts.auto_submit_success = true
  chat.opts.auto_submit_errors = true

  -- 移除 Display Chat 的保护标记（允许正常操作）
  if chat.bufnr and vim.api.nvim_buf_is_valid(chat.bufnr) then
    vim.b[chat.bufnr]._multi_agent_protected = nil
  end

  -- 使用 agent_executor 执行
  local executor = require("maxa.mcphub.native_servers.subagent.tools.agent_executor")
  executor.execute({
    chat = chat,
    prompt = nil, -- prompt 已在 _start_phase2() 中添加
    max_turns = self._final_max_turns,
    on_complete = function(result)
      self._phase2_result = result
      self:_on_phase2_complete("completed")
    end,
    on_error = function(err)
      self:_on_phase2_complete("error:" .. err)
    end,
  })
end

--- Phase 2 Run 模式：对齐 run_agent 的 inherit/独立 模型
function Coordinator:_start_phase2_run()
  log:debug("[Coordinator] Phase 2 Run mode starting")

  local chat = self.display_chat
  if not chat then
    self:_on_phase2_complete("error:Display Chat not found")
    return
  end

  local utils = require("maxa.mcphub.native_servers.subagent.utils")
  local cfg = self._final_agent_config or {}

  -- 推断 inherit 模式（与 run_agent 逻辑一致）
  local use_inherit = utils.infer_inherit_mode(cfg, self._parent_chat ~= nil)

  local valid, config_err = utils.validate_soul_params(cfg)
  if valid then
    valid, config_err = utils.validate_inherit_exclusivity(cfg, use_inherit)
  end
  if not valid then
    log:error("[Coordinator] Phase 2 Run: %s", config_err)
    self:_on_phase2_complete("error:" .. tostring(config_err))
    return
  end
  local soul_system_prompt = use_inherit and utils.inherit_system_prompt_from_parent(self._parent_chat) or nil
  if not soul_system_prompt or soul_system_prompt == "" then
    local ctx = self._parent_chat and self._parent_chat.opts or chat.opts
    local sp_err
    soul_system_prompt, sp_err = utils.build_soul_system_prompt(cfg, ctx)
    if sp_err then
      log:error("[Coordinator] Phase 2 Run: Soul resolve failed: %s", sp_err)
      self:_on_phase2_complete("error:" .. tostring(sp_err))
      return
    end
  end

  local adapter = utils.resolve_adapter_by_key(cfg.adapter, self._parent_chat)
  if not adapter then
    self:_on_phase2_complete("error:Failed to resolve final adapter")
    return
  end
  self:_configure_final_chat(adapter, soul_system_prompt)

  -- Explicit restrictions apply independently of Soul/context inheritance.
  if cfg.restrict_tools ~= nil then
    utils.apply_tools_override(chat, cfg.restrict_tools)
  elseif use_inherit and self._parent_chat then
    utils.inherit_tool_registry(self._parent_chat, chat)
  else
    utils.apply_tools_override(chat, nil)
  end

  -- [AbilityHook] 注册 cascade parent_chain（Phase 2 run 继承父 hook 链）
  if self._parent_chat then
    local sh_ok, sh_registry = pcall(require, "maxa.abilities.hooks.registry")
    if sh_ok then
      sh_registry.register_parent_chain(self._parent_chat.id, chat.id)
    end
  end

  -- 设置 auto_submit 相关配置（非交互模式）
  chat.opts = chat.opts or {}
  chat.opts.auto_submit_success = true
  chat.opts.auto_submit_errors = true

  -- 移除 Display Chat 的保护标记（允许正常操作）
  if chat.bufnr and vim.api.nvim_buf_is_valid(chat.bufnr) then
    vim.b[chat.bufnr]._multi_agent_protected = nil
  end

  -- 使用 agent_executor 执行
  local executor = require("maxa.mcphub.native_servers.subagent.tools.agent_executor")
  executor.execute({
    chat = chat,
    prompt = nil, -- prompt 已在 _start_phase2() 中添加
    max_turns = self._final_max_turns,
    on_complete = function(result)
      self._phase2_result = result
      self:_on_phase2_complete("completed")
    end,
    on_error = function(err)
      self:_on_phase2_complete("error:" .. err)
    end,
  })
end

--- Phase 2 完成后的处理
---@param reason string 完成原因
function Coordinator:_on_phase2_complete(reason)
  log:debug("[Coordinator] Phase 2 complete, reason=%s, turns=%d", reason, self._phase2_turn)

  -- 标记 Phase 2 已完成，允许 cleanup() 执行
  self._phase2_completed = true
  if reason:sub(1, 6) == "error:" then
    self._error_reported = true
    if self.on_error then self.on_error(reason:sub(7)) end
    self:_finish("phase2_error")
    return
  end

  -- ⭐ 清理 Display Chat 中 CC ready_chat_buffer 产生的 "## Me" header
  -- CC 的 done() 回调中 ready_chat_buffer 会添加空 user 消息，产生 "## Me" header
  if self.display_chat and self.display_chat.bufnr and vim.api.nvim_buf_is_valid(self.display_chat.bufnr) then
    local bufnr = self.display_chat.bufnr
    if self.display_chat.ui then self.display_chat.ui:unlock_buf() end
    local total = vim.api.nvim_buf_line_count(bufnr)
    -- 从末尾往前搜索 "## Me" header（通常在最后几行）
    for i = total, math.max(1, total - 10), -1 do
      local line = vim.api.nvim_buf_get_lines(bufnr, i - 1, i, false)[1]
      if line and line:match("^## Me") then
        -- 删除从 "## Me" 到 buffer 末尾的所有行
        vim.api.nvim_buf_set_lines(bufnr, i - 1, -1, false, {})
        -- 清理 extmark headers
        local ns_header = vim.api.nvim_create_namespace("MaxaAI-headers")
        local marks = vim.api.nvim_buf_get_extmarks(bufnr, ns_header, { i - 1, 0 }, { -1, -1 }, {})
        for _, mark in ipairs(marks) do
          vim.api.nvim_buf_del_extmark(bufnr, ns_header, mark[1])
        end
        break
      end
    end
    if self.display_chat.ui then self.display_chat.ui:lock_buf() end
  end

  -- 提取最终响应
  local utils = require("maxa.mcphub.native_servers.subagent.utils")
  local final_response = nil

  if self.display_chat and self.display_chat.messages then
    final_response = utils.extract_final_response(self.display_chat.messages)
  end

  -- 保存 Phase 2 结果
  self._phase2_result = {
    content = final_response or "(No response captured)",
    turns_used = self._phase2_turn,
    max_turns = (self._final_max_turns == math.huge or not self._final_max_turns) and -1 or self._final_max_turns,
    finish_reason = reason,
    save_id = self.display_chat and utils.get_chat_save_id(self.display_chat) or nil,
  }

  log:debug(
    "[Coordinator] Phase 2 result: content_len=%d, turns=%d, reason=%s",
    #(final_response or ""),
    self._phase2_turn,
    reason
  )

  -- 调用 _finish 执行真正的结束逻辑
  self:_finish("phase2_" .. reason)
end

return Coordinator
