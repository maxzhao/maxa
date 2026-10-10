-- Shared stale-buffer checks used directly by Chat UI owners.
local M = {}

function M.valid(bufnr)
  return type(bufnr) == "number" and vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_is_loaded(bufnr)
end

function M.abort(chat, reason)
  if type(chat) ~= "table" or M.valid(chat.bufnr) or chat.__maxa_ai_stale_buffer_aborted then
    return not M.valid(chat and chat.bufnr)
  end
  chat.__maxa_ai_stale_buffer_aborted = true
  if chat.current_tool then
    local job = chat.current_tool
    chat.current_tool = nil
    pcall(function()
      if type(job.cancel) == "function" then job.cancel() elseif type(job) == "function" then job() end
    end)
  end
  if chat.current_request then
    local request = chat.current_request
    chat.current_request = nil
    pcall(function() if type(request.cancel) == "function" then request.cancel() end end)
    pcall(function()
      if chat.adapter then require("maxa.adapters").call_handler(chat.adapter, "on_exit") end
    end)
  end
  chat.status = "stopped"
  pcall(function() if type(chat.dispatch) == "function" then chat:dispatch("on_cancelled", reason) end end)
  return true
end

function M.ensure(ui)
  if M.valid(ui and ui.chat_bufnr) then
    return ui.chat_bufnr
  end
  local ok, ai = pcall(require, "maxa")
  if not ok then
    return nil
  end
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if M.valid(bufnr) then
      local chat = ai.buf_get_chat(bufnr)
      if chat and ((chat.ui == ui) or (ui.chat_id and chat.id == ui.chat_id)) and M.valid(chat.bufnr) then
        ui.chat_bufnr = chat.bufnr
        return chat.bufnr
      end
    end
  end
  return nil
end

return M
