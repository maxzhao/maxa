-- subagent_tab_manager.lua
-- 会话级子代理 Tab 窗口管理模块
--
-- 目标：为 run_agent / resume_agent / fork_agent 提供非抢焦点的
-- 子代理窗口管理。每个顶层父 chat 关联一个专用 tab；其派生的子代理窗口
-- 均追加到该 tab 的最右侧，单行横向排列。

local M = {}

-- root_chat_key -> { tabpage = tabpage, windows_by_chat_key = {}, order = {} }
local roots = {}

-- chat_key -> root_chat_key
local chat_roots = {}

local function chat_key(chat, fallback)
  if chat and chat.id ~= nil then
    return tostring(chat.id)
  end
  if chat and chat.bufnr ~= nil then
    return "buf:" .. tostring(chat.bufnr)
  end
  if fallback ~= nil then
    return "fallback:" .. tostring(fallback)
  end
  return nil
end

local function is_valid_tab(tabpage)
  return tabpage ~= nil and pcall(vim.api.nvim_tabpage_is_valid, tabpage) and vim.api.nvim_tabpage_is_valid(tabpage)
end

local function is_valid_win(win)
  return win ~= nil and pcall(vim.api.nvim_win_is_valid, win) and vim.api.nvim_win_is_valid(win)
end

local function capture_view()
  local ok_tab, tabpage = pcall(vim.api.nvim_get_current_tabpage)
  local ok_win, win = pcall(vim.api.nvim_get_current_win)
  return {
    tabpage = ok_tab and tabpage or nil,
    win = ok_win and win or nil,
  }
end

local function restore_view(view)
  if not view then
    return
  end

  -- 恢复只用于撤销本模块为创建/调整 tab 所做的临时切换；如果用户原位置
  -- 已经失效，不主动跳到其他指定位置，交给 Neovim 默认状态。
  if is_valid_tab(view.tabpage) then
    pcall(vim.api.nvim_set_current_tabpage, view.tabpage)
    if is_valid_win(view.win) then
      pcall(vim.api.nvim_set_current_win, view.win)
    end
  end
end

local function cleanup_invalid_windows(root)
  if not root then
    return
  end

  local next_order = {}
  for _, key in ipairs(root.order or {}) do
    local win = root.windows_by_chat_key[key]
    if is_valid_win(win) then
      table.insert(next_order, key)
    else
      root.windows_by_chat_key[key] = nil
      chat_roots[key] = nil
    end
  end
  root.order = next_order
end

local function remove_from_order(root, key)
  if not root or not root.order then
    return
  end
  local next_order = {}
  for _, existing in ipairs(root.order) do
    if existing ~= key then
      table.insert(next_order, existing)
    end
  end
  root.order = next_order
end

local function is_chat_active_displayed(chat, bufnr)
  local target_bufnr = (chat and chat.bufnr) or bufnr
  if not target_bufnr or not vim.api.nvim_buf_is_valid(target_bufnr) then
    return false
  end

  local current_win = vim.api.nvim_get_current_win()
  if not is_valid_win(current_win) then
    return false
  end

  if vim.api.nvim_win_get_buf(current_win) ~= target_bufnr then
    return false
  end

  -- 如果 UI 层有可见性判断，也要满足它；没有 ui 时以当前窗口 buffer 为准。
  if chat and chat.ui and type(chat.ui.is_visible) == "function" then
    local ok, visible = pcall(function()
      return chat.ui:is_visible()
    end)
    if ok and visible == false then
      return false
    end
  end

  return true
end

local function root_for_parent(parent_chat, parent_bufnr)
  local parent_key = chat_key(parent_chat, parent_bufnr)
  if not parent_key then
    return nil, nil
  end

  local root_key = chat_roots[parent_key] or parent_key
  local root = roots[root_key]
  if root and not is_valid_tab(root.tabpage) then
    roots[root_key] = nil
    root = nil
  end

  if not root then
    root = {
      tabpage = nil,
      windows_by_chat_key = {},
      order = {},
    }
    roots[root_key] = root
  end

  -- 顶层父 chat 本身不放入 tab，但记录 root 映射，便于同一父 chat 后续复用。
  chat_roots[parent_key] = root_key

  return root_key, root
end

local function close_auto_window(child_chat)
  local chat_winnr = child_chat and child_chat.ui and child_chat.ui.winnr
  if is_valid_win(chat_winnr) then
    pcall(vim.api.nvim_win_close, chat_winnr, false) -- 保留 buffer
  end
end

local function create_tab_with_child(root, child_chat)
  vim.cmd("tabnew")
  root.tabpage = vim.api.nvim_get_current_tabpage()
  local win = vim.api.nvim_get_current_win()
  local placeholder_buf = vim.api.nvim_win_get_buf(win)
  vim.api.nvim_win_set_buf(win, child_chat.bufnr)

  -- tabnew 会创建一个临时空 buffer。切到 child buffer 后尽量清理它，避免
  -- 子代理 tab 生命周期中反复留下无名空 buffer。若 buffer 已被用户/插件改动，
  -- 条件不满足时不强制删除。
  if placeholder_buf ~= child_chat.bufnr and vim.api.nvim_buf_is_valid(placeholder_buf) then
    local ok_name, name = pcall(vim.api.nvim_buf_get_name, placeholder_buf)
    local ok_lines, lines = pcall(vim.api.nvim_buf_get_lines, placeholder_buf, 0, -1, false)
    if ok_name and ok_lines and name == "" and #lines == 1 and lines[1] == "" then
      pcall(vim.api.nvim_buf_delete, placeholder_buf, { force = true })
    end
  end

  return win
end

local function append_child_window(root, child_chat)
  vim.api.nvim_set_current_tabpage(root.tabpage)

  local anchor_win = nil
  for i = #(root.order or {}), 1, -1 do
    local key = root.order[i]
    local win = root.windows_by_chat_key[key]
    if is_valid_win(win) then
      anchor_win = win
      break
    end
  end

  if anchor_win then
    pcall(vim.api.nvim_set_current_win, anchor_win)
  else
    local wins = vim.api.nvim_tabpage_list_wins(root.tabpage)
    for _, win in ipairs(wins) do
      if is_valid_win(win) then
        anchor_win = win
        pcall(vim.api.nvim_set_current_win, win)
        break
      end
    end
  end

  vim.cmd("botright vsplit")
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, child_chat.bufnr)
  return win
end

local function equalize_columns(root)
  if not root or not is_valid_tab(root.tabpage) then
    return
  end
  pcall(function()
    vim.api.nvim_set_current_tabpage(root.tabpage)
    vim.cmd("wincmd =")
  end)
end

local function close_root_tab_if_empty(root_key, root)
  cleanup_invalid_windows(root)
  if #root.order > 0 then
    return
  end

  roots[root_key] = nil

  if is_valid_tab(root.tabpage) then
    -- 不主动跳回父/源 tab。关闭 tab 若需要 Neovim 改变当前 tab，则由 Neovim
    -- 默认行为决定；调用方外层会尽量恢复调用前用户所在窗口。
    local wins = vim.api.nvim_tabpage_list_wins(root.tabpage)
    for _, win in ipairs(wins) do
      if is_valid_win(win) then
        pcall(vim.api.nvim_win_close, win, true)
      end
    end
  end
end

--- 创建会话级 tab 管理器实例
--- @param parent_chat table 父 chat 实例
--- @param parent_bufnr number 父 buffer 编号
--- @return table manager
function M.new(parent_chat, parent_bufnr)
  local parent_key = chat_key(parent_chat, parent_bufnr)
  local parent_was_known_child = parent_key ~= nil and chat_roots[parent_key] ~= nil
  local root_parent_active = (not parent_was_known_child) and is_chat_active_displayed(parent_chat, parent_bufnr)
  local root_key, root = root_for_parent(parent_chat, parent_bufnr)

  local self = {
    parent_chat = parent_chat,
    parent_bufnr = parent_bufnr,
    root_key = root_key,
    -- M.new() 在 Chat.new() 之前调用；此时的视图更接近用户原始位置。
    -- setup_child_window() 发生时，Chat.new() 可能已经打开并聚焦了临时子窗口，
    -- 因此不能用 setup 时的 current window 作为恢复目标。
    creation_view = capture_view(),
    jump_to_subagent_tab = root_parent_active,
  }

  --- 兼容旧 window_manager 接口；tab manager 不恢复/打开父窗口，避免抢焦点。
  function self:restore_parent_window()
    -- no-op by design
  end

  --- 将子 chat 加入 root tab 的最右侧列。
  --- @param child_chat table 子 chat 实例
  function self:setup_child_window(child_chat)
    if not child_chat or not child_chat.bufnr or not self.root_key then
      return
    end

    local child_key = chat_key(child_chat)
    if not child_key then
      return
    end

    local current_root = roots[self.root_key]
    if not current_root then
      _, current_root = root_for_parent(self.parent_chat, self.parent_bufnr)
    end
    if not current_root then
      return
    end

    local view = self.creation_view or capture_view()

    close_auto_window(child_chat)

    cleanup_invalid_windows(current_root)

    local ok, win = pcall(function()
      if not is_valid_tab(current_root.tabpage) then
        return create_tab_with_child(current_root, child_chat)
      end
      return append_child_window(current_root, child_chat)
    end)

    if ok and is_valid_win(win) then
      current_root.windows_by_chat_key[child_key] = win
      remove_from_order(current_root, child_key)
      table.insert(current_root.order, child_key)
      chat_roots[child_key] = self.root_key
      if child_chat.ui then
        child_chat.ui.winnr = win
      end
      equalize_columns(current_root)
    end

    if self.jump_to_subagent_tab and is_valid_tab(current_root.tabpage) then
      pcall(vim.api.nvim_set_current_tabpage, current_root.tabpage)
      local child_win = current_root.windows_by_chat_key[child_key]
      if is_valid_win(child_win) then
        pcall(vim.api.nvim_set_current_win, child_win)
      end
    else
      restore_view(view)
    end
  end

  --- 关闭子代理窗口；若 root tab 已空则关闭 tab。
  --- @param child_chat table|nil 子 chat 实例
  function self:close_child_window(child_chat)
    if not self.root_key then
      return
    end

    local root_state = roots[self.root_key]
    if not root_state then
      return
    end

    local key = chat_key(child_chat)
    local view = capture_view()

    if key then
      local win = root_state.windows_by_chat_key[key]
      if is_valid_win(win) then
        pcall(vim.api.nvim_win_close, win, true)
      end
      root_state.windows_by_chat_key[key] = nil
      remove_from_order(root_state, key)
      chat_roots[key] = nil
    end

    close_root_tab_if_empty(self.root_key, root_state)
    restore_view(view)
  end

  --- 清理并关闭子 chat。
  --- @param child_chat table|nil 子 chat 实例
  function self:cleanup(child_chat)
    self:close_child_window(child_chat)
    if child_chat then
      child_chat:close()
    end
  end

  return self
end

--- 复用旧 window_manager 的子代理键位实现，保持 Ctrl+C/q 语义一致。
function M.setup_subagent_keymaps(child_chat, on_cancel)
  local ok, window_manager = pcall(require, "maxa.mcphub.native_servers.subagent.tools.window_manager")
  if ok and window_manager and type(window_manager.setup_subagent_keymaps) == "function" then
    return window_manager.setup_subagent_keymaps(child_chat, on_cancel)
  end
end

function M.is_interrupted(child_chat)
  local ok, window_manager = pcall(require, "maxa.mcphub.native_servers.subagent.tools.window_manager")
  if ok and window_manager and type(window_manager.is_interrupted) == "function" then
    return window_manager.is_interrupted(child_chat)
  end
  return child_chat and child_chat._subagent_interrupted == true
end

function M.reset_interrupted(child_chat)
  local ok, window_manager = pcall(require, "maxa.mcphub.native_servers.subagent.tools.window_manager")
  if ok and window_manager and type(window_manager.reset_interrupted) == "function" then
    return window_manager.reset_interrupted(child_chat)
  end
  if child_chat then
    child_chat._subagent_interrupted = false
  end
end

-- 测试/调试辅助，不作为公共 MCP API。
function M._state()
  return {
    roots = roots,
    chat_roots = chat_roots,
  }
end

return M
