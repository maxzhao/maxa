-- Bounded stdout/stderr collector for builtin execution tools.
--
-- Keeps small command output in memory for direct LLM-facing responses. Once
-- total output exceeds the configured threshold, it creates a temp log,
-- flushes already captured chunks, and streams all subsequent output directly
-- to that log. This prevents Neovim Lua callbacks from accumulating unbounded
-- strings while preserving the existing small-output behavior.

local builtin_utils = require("maxa.interactions.chat.tools.builtin.runtime.utils")

local Collector = {}
Collector.__index = Collector

---@param opts table|nil
---@return table
function Collector.new(opts)
  opts = opts or {}
  local self = setmetatable({}, Collector)
  self.max_chars = tonumber(opts.max_chars) or builtin_utils.MAX_OUTPUT_CHARS
  self.log_prefix = opts.log_prefix or "mcpx_output"
  self.stdout_chunks = {}
  self.stderr_chunks = {}
  self.preview = ""
  self.preview_chars = 0
  self.total_chars = 0
  self.line_count = 0
  self.max_line_chars = 0
  self.is_exceeded = false
  self.log_file = nil
  self.log_handle = nil
  self.log_write_err = nil
  return self
end

function Collector:close()
  if self.log_handle then
    local handle = self.log_handle
    self.log_handle = nil
    local ok, err = pcall(function()
      handle:flush()
      handle:close()
    end)
    if not ok and not self.log_write_err then
      self.log_write_err = tostring(err)
    end
  end
end

function Collector:ensure_log()
  if self.log_write_err then
    return false
  end
  if self.log_handle then
    return true
  end

  self.log_file = self.log_file or builtin_utils.make_temp_log(self.log_prefix)
  local handle, err = io.open(self.log_file, "w")
  if not handle then
    self.log_write_err = tostring(err)
    return false
  end
  self.log_handle = handle

  local ok, write_err = pcall(function()
    for _, chunk in ipairs(self.stdout_chunks) do
      handle:write(chunk)
    end
    for _, chunk in ipairs(self.stderr_chunks) do
      handle:write(chunk)
    end
  end)
  if not ok then
    self.log_write_err = tostring(write_err)
    self:close()
    return false
  end

  self.stdout_chunks = {}
  self.stderr_chunks = {}
  return true
end

---@param stream "stdout"|"stderr"
---@param chunk string
function Collector:append_chunk(stream, chunk)
  chunk = tostring(chunk or "")
  if chunk == "" then
    return
  end

  if self.preview_chars < 240 then
    local part = vim.fn.strcharpart(chunk, 0, 240 - self.preview_chars)
    self.preview = self.preview .. part
    self.preview_chars = self.preview_chars + vim.fn.strchars(part)
  end
  self.total_chars = self.total_chars + #chunk
  if self.total_chars > self.max_chars then
    self.is_exceeded = true
  end

  if self.is_exceeded then
    if self:ensure_log() then
      local ok, err = pcall(function()
        self.log_handle:write(chunk)
      end)
      if not ok then
        self.log_write_err = tostring(err)
        self:close()
      end
    end
  else
    table.insert(self[stream .. "_chunks"], chunk)
  end
end

---@param stream "stdout"|"stderr"
---@param data string[]|nil
---@param opts table|nil
function Collector:append_lines(stream, data, opts)
  if not data then
    return
  end
  opts = opts or {}
  local filter_line = opts.filter_line
  local chunks = {}

  for _, line in ipairs(data) do
    if line ~= "" then
      if filter_line then
        local keep, replacement = filter_line(line, stream)
        if keep == false then
          goto continue
        end
        if replacement ~= nil then
          line = tostring(replacement)
        end
      end

      self.line_count = self.line_count + 1
      if #line > self.max_line_chars then
        self.max_line_chars = #line
      end
      table.insert(chunks, line .. "\n")
    end
    ::continue::
  end

  if #chunks > 0 then
    self:append_chunk(stream, table.concat(chunks))
  end
end

function Collector:exceeded()
  return self.is_exceeded
end

function Collector:error()
  return self.log_write_err
end

function Collector:stdout()
  return table.concat(self.stdout_chunks)
end

function Collector:stderr()
  return table.concat(self.stderr_chunks)
end

function Collector:stats()
  return {
    total_chars = self.total_chars,
    line_count = self.line_count,
    max_line_chars = self.max_line_chars,
    max_chars = self.max_chars,
    log_file = self.log_file,
  }
end

---@param header string
---@param next_text string|nil
---@return string|nil result
---@return string|nil err
function Collector:overflow_result(header)
  if not self.log_file then
    return nil, "output exceeded limit, but no output log was created"
  end
  local stats = self:stats()
  local preview = self.preview:gsub("\r", "\\r"):gsub("\n", "\\n")
  return (header or "")
    .. "Preview: " .. preview .. (#self.preview < stats.total_chars and "…" or "") .. "\n"
    .. "Full output: " .. stats.log_file .. "\n"
    .. "Size: " .. stats.total_chars .. " chars", nil
end

return Collector
