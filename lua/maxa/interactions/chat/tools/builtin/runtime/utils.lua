-- Chat builtin 公共工具函数

local M = {}

---Validate a required string while preserving builtin error messages.
---@param value any
---@param param_name string
---@return boolean, string|nil
function M.validate_required_string(value, param_name)
  if value == nil or value == vim.NIL then
    return false, param_name .. " parameter is required. Please provide a valid value."
  end
  if type(value) ~= "string" then
    return false, param_name .. " parameter must be a string, got " .. type(value) .. "."
  end
  if value == "" or value:match("^%s*$") then
    return false, param_name .. " parameter cannot be empty. Please provide a valid value."
  end
  return true, nil
end

-- 共享常量
M.MAX_OUTPUT_CHARS = 10500
M.MAX_PREVIEW_CHARS = 240
-- call 错误输出相对更需要保留上下文；超过该阈值才落盘摘要。
M.MAX_ERROR_OUTPUT_CHARS = 4096
M.MAX_ERROR_PREVIEW_CHARS = 240

local function count_lines(text)
  text = tostring(text or "")
  if text == "" then
    return 0
  end
  local _, count = text:gsub("\n", "")
  return count + 1
end

local function short_sha256(text)
  local ok, hash = pcall(vim.fn.sha256, tostring(text or ""))
  if ok and type(hash) == "string" and hash ~= "" then
    return hash:sub(1, 12)
  end
  return nil
end

--- Build a bounded, single-line-friendly preview for LLM-facing tool results.
---@param text string
---@param opts table|nil
---@return string
function M.preview_text(text, opts)
  opts = opts or {}
  text = tostring(text or "")
  local max_chars = tonumber(opts.max_chars) or M.MAX_PREVIEW_CHARS
  local single_line = opts.single_line ~= false
  local preview_source = text

  if single_line then
    preview_source = preview_source:gsub("\r\n", "\n"):gsub("\r", "\n"):gsub("\n", "\\n")
  end

  if max_chars <= 0 or #preview_source <= max_chars then
    return preview_source
  end

  local details = {}
  if opts.include_chars ~= false then
    table.insert(details, tostring(#text) .. " chars")
  end
  if opts.include_lines ~= false then
    table.insert(details, tostring(count_lines(text)) .. " lines")
  end
  if opts.include_hash ~= false then
    local hash = short_sha256(text)
    if hash then
      table.insert(details, "sha256=" .. hash)
    end
  end

  local suffix = opts.suffix or "…"
  local detail_text = #details > 0 and (" [truncated; " .. table.concat(details, ", ") .. "]") or " [truncated]"
  return preview_source:sub(1, max_chars) .. suffix .. detail_text
end

--- Format command input for execution tool results without echoing long commands.
---@param command string
---@param opts table|nil
---@return string
function M.format_command_preview(command, opts)
  opts = opts or {}
  opts.max_chars = tonumber(opts.max_chars) or M.MAX_PREVIEW_CHARS
  opts.single_line = true
  opts.include_chars = opts.include_chars ~= false
  opts.include_lines = opts.include_lines ~= false
  opts.include_hash = opts.include_hash ~= false
  return M.preview_text(command, opts)
end

--- 计算相对路径（优先精确调用项目根，fallback nvim config 根）
--- 计算相对路径（优先项目根，fallback nvim config 根）
--- 当从其他项目的 chat 编辑全局配置文件（abilities/mcphub/mcp-servers）时，
--- 项目根不匹配，但 nvim config 根仍能产生有效 rel_path 供 hook filter 匹配。
---@param abs_path string 绝对路径
---@return string|nil 相对路径（两个根都不匹配时返回 nil）
local function compute_rel_path(abs_path, project_root)
  -- 1. 优先：相对于调用 Chat 的项目根
  local root = project_root
  if root then
    if root:sub(-1) ~= "/" then
      root = root .. "/"
    end
    if abs_path:sub(1, #root) == root then
      return abs_path:sub(#root + 1)
    end
  end
  -- 2. Fallback：相对于 nvim config 根（全局 abilities/mcphub/mcp-servers 等）
  local config_root = vim.fn.stdpath("config")
  if config_root then
    if config_root:sub(-1) ~= "/" then
      config_root = config_root .. "/"
    end
    -- 避免重复匹配（项目根 == config 根时已在上面匹配过）
    if config_root ~= root and abs_path:sub(1, #config_root) == config_root then
      return abs_path:sub(#config_root + 1)
    end
  end
  return nil
end

--- 触发 FileOperation AbilityHook 事件
--- 在文件操作工具成功后调用，通知 AbilityHook 系统
---@param context table MCP 工具请求对象
---@param operation string "create" | "modify" | "read" | "delete"
---@param path string 文件路径（会被规范化为绝对路径）
---@param tool string 触发工具名（如 "write"）
function M.fire_file_event(context, operation, path, tool)
  local ok, err = pcall(function()
    local fire = require("maxa.abilities.hooks.fire")
    local bufnr = context and context.bufnr
    if not bufnr then
      return
    end

    local abs_path = vim.fn.fnamemodify(path, ":p")
    local rel_path = compute_rel_path(abs_path, context and context.cwd)

    fire.fire("FileOperation", {
      bufnr = bufnr,
      operation = operation,
      path = abs_path,
      rel_path = rel_path,
      tool = tool,
    })
  end)
  if not ok then
    vim.notify(
      string.format("[builtin-tools] Failed to fire FileOperation event for %s: %s", tostring(path), tostring(err)),
      vim.log.levels.DEBUG
    )
  end
end

--- 生成唯一的临时日志文件路径
--- 使用 os.time() + 原子递增计数器，确保并行调用不冲突
---@param prefix string 文件名前缀（如 "mcpx_cmd", "mcpx_wincmd"）
---@return string 临时文件路径
local _log_counter = 0
function M.make_temp_log(prefix)
  _log_counter = _log_counter + 1
  return string.format("/tmp/%s_%d_%d.log", prefix, os.time(), _log_counter)
end

--- 重新加载已打开且未修改的 buffer
---@param file_path string 文件路径
function M.reload_buffer_if_needed(file_path)
  local ok, err = pcall(function()
    local abs_path = vim.fn.fnamemodify(file_path, ":p")

    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_loaded(bufnr) then
        local buf_name = vim.api.nvim_buf_get_name(bufnr)
        if buf_name == abs_path then
          -- buffer 未修改时才重载
          if not vim.bo[bufnr].modified then
            vim.api.nvim_buf_call(bufnr, function()
              vim.cmd("edit!")
            end)
          end
          break
        end
      end
    end
  end)
  if not ok then
    vim.notify(
      string.format("[builtin-tools] Failed to reload buffer for %s: %s", tostring(file_path), tostring(err)),
      vim.log.levels.DEBUG
    )
  end
end

return M
