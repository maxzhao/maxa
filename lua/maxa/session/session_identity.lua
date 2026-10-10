local M = {}

local function non_empty_string(value)
  return type(value) == "string" and value ~= "" and value or nil
end

---@param chat table|nil
---@return string|nil
function M.save_id(chat)
  if type(chat) ~= "table" then
    return nil
  end
  local opts = type(chat.opts) == "table" and chat.opts or {}
  local save_id = non_empty_string(opts.save_id) or non_empty_string(chat.save_id)
  if not save_id or save_id:match("[/\\]") then
    return nil
  end
  return save_id
end

---@param chat table|nil
---@return string|nil
function M.project_root(chat)
  if type(chat) ~= "table" then
    return nil
  end
  local opts = type(chat.opts) == "table" and chat.opts or {}
  local cwd = non_empty_string(opts.cwd) or non_empty_string(chat.cwd)
  if cwd then
    return vim.fs.root(cwd, { ".maxa" })
  end
  if type(chat.bufnr) == "number" and vim.api.nvim_buf_is_valid(chat.bufnr) then
    return vim.fs.root(chat.bufnr, { ".maxa" })
  end
  return nil
end

---@param chat table|nil
---@return table|nil
function M.resolve(chat)
  local project_root = M.project_root(chat)
  local save_id = M.save_id(chat)
  if not project_root or not save_id then
    return nil
  end
  return {
    project_root = project_root,
    save_id = save_id,
  }
end

return M
