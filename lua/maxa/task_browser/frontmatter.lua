-- filepath: lua/maxa/task_browser/frontmatter.lua
-- Lightweight read-only parser for TaskAdmin bare `_meta.yaml` files.

local M = {}

local function trim(value)
  if type(value) ~= "string" then
    return value
  end
  return (value:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function unquote(value)
  value = trim(value)
  local first = value:sub(1, 1)
  local last = value:sub(-1)
  if (first == '"' and last == '"') or (first == "'" and last == "'") then
    return value:sub(2, -2)
  end
  return value
end

local function parse_scalar(value)
  value = trim(value or "")
  if value == "" then
    return ""
  end
  if value == "true" then
    return true
  end
  if value == "false" then
    return false
  end
  if value == "null" or value == "~" then
    return nil
  end
  if value:match("^%-?%d+$") then
    return tonumber(value)
  end
  return unquote(value)
end

function M.parse_value(value)
  value = trim(value or "")
  if value:sub(1, 1) == "[" and value:sub(-1) == "]" then
    local body = trim(value:sub(2, -2))
    local result = {}
    if body == "" then
      return result
    end
    for item in body:gmatch("([^,]+)") do
      table.insert(result, parse_scalar(item))
    end
    return result
  end
  return parse_scalar(value)
end

---@param content string|nil
---@return table data
---@return string|nil err
function M.parse(content)
  if type(content) ~= "string" or content == "" then
    return {}, "empty content"
  end
  if content:match("^%-%-%-") then
    return {}, "frontmatter-wrapped metadata is unsupported"
  end

  local data = {}
  for line in (content:gsub("\r\n", "\n") .. "\n"):gmatch("(.-)\n") do
    local stripped = trim(line)
    if stripped ~= "" and stripped:sub(1, 1) ~= "#" then
      local key, value = stripped:match("^([%w_%-]+)%s*:%s*(.*)$")
      if not key then
        return {}, "unsupported metadata line: " .. stripped
      end
      data[key] = M.parse_value(value)
    end
  end
  return data, nil
end

---@param path string
---@return table data
---@return string|nil err
function M.parse_file(path)
  if type(path) ~= "string" or path == "" then
    return {}, "invalid path"
  end
  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok or type(lines) ~= "table" then
    return {}, "read failed"
  end
  return M.parse(table.concat(lines, "\n"))
end

return M
