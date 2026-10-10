-- Pure formatting primitives shared by tool-owned display methods.
local M = {}

function M.normalize_args(args)
  if type(args) == "table" then return args end
  if type(args) == "string" and args ~= "" then
    local ok, decoded = pcall(vim.json.decode, args)
    if ok and type(decoded) == "table" then return decoded end
  end
  return {}
end

function M.atom(value, max_chars)
  value = value:gsub("%c", " "):gsub("%s+", " ")
  if vim.fn.strchars(value) > max_chars then
    return vim.fn.strcharpart(value, 0, max_chars) .. "…"
  end
  return value
end

function M.format_path(filepath)
  if type(filepath) ~= "string" or filepath == "" then return "" end
  local abs = filepath:sub(1, 1) == "~" and vim.fn.expand(filepath) or filepath
  local cwd = vim.uv.cwd() or vim.fn.getcwd(-1, -1)
  if cwd:sub(-1) ~= "/" then cwd = cwd .. "/" end
  if abs:sub(1, #cwd) == cwd then return abs:sub(#cwd + 1) end
  local home = vim.fn.expand("~")
  if home:sub(-1) ~= "/" then home = home .. "/" end
  if abs:sub(1, #home) == home then return "~/" .. abs:sub(#home + 1) end
  return filepath
end

function M.format_range(args)
  local s, e = tonumber(args.start_line), tonumber(args.end_line)
  if s and e and e > 0 then return string.format(" L%d-%d", s, e) end
  if s and s > 1 then return string.format(" L%d-", s) end
  return ""
end

function M.path_detail(name, args, with_range)
  local path = M.format_path(args.path)
  return path ~= "" and (name .. " " .. path .. (with_range and M.format_range(args) or "")) or name
end

function M.title_detail(name, args, max_chars)
  local title = type(args.title) == "string" and args.title or ""
  if max_chars then
    if not title:find("%S") then return name end
    title = M.atom(title, max_chars)
  end
  return title ~= "" and (name .. ' "' .. title .. '"') or name
end

function M.query_detail(name, values, args)
  local patterns = type(values) == "string" and { values } or (type(values) == "table" and values or {})
  local first = patterns[1]
  if first ~= nil and (type(first) ~= "string" or first == "") then return name end
  local pattern = first and ('"' .. M.atom(first, 48):gsub('"', '\\"') .. '"') or "all"
  local extra = #patterns > 1 and (" (+" .. (#patterns - 1) .. ")") or ""
  local scope = type(args.scope) == "string" and args.scope ~= "" and args.scope or "."
  return name .. " " .. pattern .. extra .. " · " .. M.atom(scope, 60)
end

-- Owning tools may decode their own text result; the host never selects business fields.
function M.decode_payload(text)
  if type(text) ~= "string" or text == "" then return nil end
  for _, candidate in ipairs({ text, text:match("````%w*%s*\n(.-)````") or "", text:match("```%w*%s*\n(.-)```") or "" }) do
    local ok, value = pcall(vim.json.decode, candidate)
    if ok and type(value) == "table" then return value end
  end
end

return M
