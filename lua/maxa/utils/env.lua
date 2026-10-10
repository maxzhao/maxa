local M = {}

local function config_root()
  return vim.fn.stdpath("config")
end

function M.path()
  local explicit = vim.env.MAXA_ENV_FILE
  if explicit and explicit ~= "" then
    return vim.fn.expand(explicit)
  end
  return vim.fs.joinpath(config_root(), ".env")
end

local function trim(value)
  return tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function unquote(value)
  value = trim(value)
  local first = value:sub(1, 1)
  local last = value:sub(-1)
  if #value >= 2 and ((first == '"' and last == '"') or (first == "'" and last == "'")) then
    value = value:sub(2, -2)
  end
  return value
end

local function read_dotenv()
  local path = M.path()
  if vim.fn.filereadable(path) ~= 1 then
    return {}
  end

  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok or type(lines) ~= "table" then
    return {}
  end

  local values = {}
  for _, line in ipairs(lines) do
    local key, value = line:match("^%s*([A-Za-z_][A-Za-z0-9_]*)%s*=%s*(.-)%s*$")
    if key then
      values[key] = unquote(value)
    end
  end
  return values
end

local cache

function M.reload()
  cache = read_dotenv()
  return cache
end

function M.all()
  if not cache then
    M.reload()
  end
  return vim.deepcopy(cache or {})
end

function M.get(key, opts)
  opts = opts or {}
  if not cache then
    M.reload()
  end

  local value = vim.env[key]
  if value == nil or value == "" then
    value = cache and cache[key]
  end

  if (value == nil or value == "") and opts.required then
    error(("missing required environment variable `%s` in %s or process env"):format(key, M.path()))
  end

  return value
end

-- Address lookup only; callers must explicitly opt into proxy routing.
function M.proxy()
  local keys = { "HTTPS_PROXY", "HTTP_PROXY", "ALL_PROXY" }
  for _, key in ipairs(keys) do
    local value = vim.env[key]
    if value and value ~= "" then return value end
  end
  for _, key in ipairs(keys) do
    local value = M.get(key)
    if value and value ~= "" then return value end
  end
  return nil
end

return M
