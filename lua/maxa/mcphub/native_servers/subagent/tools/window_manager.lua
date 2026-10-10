-- window_manager.lua
-- 子代理/工作流窗口管理模块
-- 提供统一的窗口创建、关闭和恢复逻辑

local M = {}

-- ============================================================================
-- 子代理键位管理
-- ============================================================================

--- Compatibility entrypoint: children use the same configured Chat controls.
--- @param child_chat table
--- @param on_cancel function|nil legacy callback; exit is owned by guarded Chat close
function M.setup_subagent_keymaps(child_chat, on_cancel)
  if child_chat then child_chat._subagent_interrupted = false end
end

--- 检查子代理是否被打断（而非取消）
--- @param child_chat table 子 chat 实例
--- @return boolean 是否被打断
function M.is_interrupted(child_chat)
  return child_chat and child_chat._subagent_interrupted == true
end

--- 重置打断标志
--- @param child_chat table 子 chat 实例
function M.reset_interrupted(child_chat)
  if child_chat then
    child_chat._subagent_interrupted = false
  end
end

--- 创建窗口管理器实例
--- @param parent_chat table 父 chat 实例
--- @param parent_bufnr number 父 buffer 编号
--- @return table window_manager 窗口管理器实例
function M.new(parent_chat, parent_bufnr)
  local self = {
    parent_chat = parent_chat,
    parent_bufnr = parent_bufnr,
    parent_winnr = nil,
    fork_winnr = nil,
  }

  -- 获取父窗口
  self.parent_winnr = (parent_chat and parent_chat.ui and parent_chat.ui.winnr) or vim.fn.bufwinid(parent_bufnr)
  if self.parent_winnr == -1 then
    self.parent_winnr = vim.api.nvim_get_current_win()
  end

  --- 在父窗口下方创建子代理窗口，并将 buffer 放入
  --- @param child_chat table 子 chat 实例
  function self:setup_child_window(child_chat)
    if not child_chat or not child_chat.bufnr then
      return
    end

    -- 关闭 Chat.new 创建的窗口（如果有）
    local chat_winnr = child_chat.ui and child_chat.ui.winnr
    if chat_winnr and vim.api.nvim_win_is_valid(chat_winnr) then
      vim.api.nvim_win_close(chat_winnr, false) -- false = 不强制关闭，保留 buffer
    end

    -- 获取父窗口（可能已经被 ui:open() 更新了）
    local actual_parent_winnr = self.parent_chat and self.parent_chat.ui and self.parent_chat.ui.winnr
    if not actual_parent_winnr or not vim.api.nvim_win_is_valid(actual_parent_winnr) then
      -- fallback: 查找显示父 buffer 的窗口
      actual_parent_winnr = vim.fn.bufwinid(self.parent_bufnr)
    end
    if actual_parent_winnr == -1 or not vim.api.nvim_win_is_valid(actual_parent_winnr) then
      -- 最后 fallback: 使用当前窗口
      actual_parent_winnr = vim.api.nvim_get_current_win()
    end

    -- 更新 parent_winnr
    self.parent_winnr = actual_parent_winnr

    -- 切换到父窗口
    vim.api.nvim_set_current_win(actual_parent_winnr)

    -- 获取分割前的总高度
    local total_height = vim.api.nvim_win_get_height(actual_parent_winnr)

    -- 在父窗口下方创建水平分割窗口
    vim.cmd("belowright split")
    self.fork_winnr = vim.api.nvim_get_current_win()

    -- 设置两个窗口各占一半高度
    local half_height = math.floor(total_height / 2)
    vim.api.nvim_win_set_height(actual_parent_winnr, half_height)
    vim.api.nvim_win_set_height(self.fork_winnr, half_height)

    -- 调整父窗口的视图，使光标保持在可见区域
    vim.api.nvim_set_current_win(actual_parent_winnr)
    -- 移动到 buffer 最后一行，然后居中显示
    vim.cmd("normal! Gzz")

    -- 将 child_chat 的 buffer 放入新窗口
    vim.api.nvim_win_set_buf(self.fork_winnr, child_chat.bufnr)

    -- 更新 child_chat.ui.winnr
    if child_chat.ui then
      child_chat.ui.winnr = self.fork_winnr
    end
  end

  --- 关闭子代理窗口并恢复焦点到父窗口
  --- @param child_chat table|nil 子 chat 实例（可选）
  function self:close_child_window(child_chat)
    -- 获取要关闭的窗口（优先使用我们创建的 fork_winnr）
    local winnr_to_close = self.fork_winnr
    if not winnr_to_close or not vim.api.nvim_win_is_valid(winnr_to_close) then
      winnr_to_close = child_chat and child_chat.ui and child_chat.ui.winnr
    end
    if winnr_to_close and vim.api.nvim_win_is_valid(winnr_to_close) then
      vim.api.nvim_win_close(winnr_to_close, true)
    end
    self.fork_winnr = nil

    -- 恢复焦点到父窗口
    if self.parent_winnr and vim.api.nvim_win_is_valid(self.parent_winnr) then
      vim.api.nvim_set_current_win(self.parent_winnr)
    end
  end

  --- 恢复父 chat 窗口（被 Chat.new() 中的 close_last_chat() 隐藏了）
  --- 只在窗口不可见时才恢复，避免创建重复窗口
  function self:restore_parent_window()
    if not self.parent_chat or not self.parent_chat.ui then
      return
    end

    -- 检查父窗口是否已经可见
    if self.parent_chat.ui:is_visible() then
      return -- 已经可见，无需恢复
    end

    -- 窗口不可见，需要恢复
    self.parent_chat.ui:open()
  end

  --- 清理并恢复原始状态
  --- @param child_chat table|nil 子 chat 实例
  function self:cleanup(child_chat)
    -- 关闭子窗口
    self:close_child_window(child_chat)
    -- 关闭子 chat
    if child_chat then
      child_chat:close()
    end
  end

  return self
end

return M
