-- Runtime-local per-medium default GenAI adapter state.
local M = {}

local KEYS = {
  image = "GENAI_DEFAULT_IMAGE_ADAPTER",
  tts = "GENAI_DEFAULT_TTS_ADAPTER",
  video = "GENAI_DEFAULT_VIDEO_ADAPTER",
}
local TEST_ENV_FILE_KEY = "MAXA_GENAI_ENV_FILE"

local function trim(value) return tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "") end
local function env_path()
  local explicit = vim.env[TEST_ENV_FILE_KEY]
  return explicit and explicit ~= "" and vim.fn.expand(explicit) or vim.fs.joinpath(vim.fn.stdpath("config"), ".env")
end
local function read_lines()
  if vim.fn.filereadable(env_path()) ~= 1 then return {} end
  local ok, lines = pcall(vim.fn.readfile, env_path())
  return ok and type(lines) == "table" and lines or {}
end
local function unquote(value)
  value = trim(value)
  local first, last = value:sub(1, 1), value:sub(-1)
  if #value >= 2 and ((first == '"' and last == '"') or (first == "'" and last == "'")) then return value:sub(2, -2) end
  return value
end
local function quote(value)
  value = tostring(value)
  if value:match("^[A-Za-z0-9_./:@%+%-]+$") then return value end
  return "'" .. value:gsub("'", "'\\''") .. "'"
end

function M.env_path() return env_path() end

function M.read_persisted()
  local result = {}
  for _, line in ipairs(read_lines()) do
    local key, value = line:match("^%s*([A-Za-z_][A-Za-z0-9_]*)%s*=%s*(.-)%s*$")
    if key then
      for medium, expected in pairs(KEYS) do if key == expected then result[medium] = unquote(value) end end
    end
  end
  return next(result) and result or nil
end

function M.get_initial_config(fallback)
  local result = vim.deepcopy(fallback or require("maxa.config").runtime().genai or {})
  result.default_adapters = result.default_adapters or {}
  if not result.defaults then
    result.defaults = {}
    for _, medium in ipairs({ "image", "tts", "video" }) do
      local selected, err = require("maxa.presets").get_default(medium)
      assert(selected, err)
      result.default_adapters[medium] = result.default_adapters[medium] or selected.adapter
      selected.adapter, selected.source = nil, nil
      result.defaults[medium] = selected
    end
  end
  for medium, value in pairs(M.read_persisted() or {}) do
    if trim(value) ~= "" then result.default_adapters[medium] = trim(value) end
  end
  return result
end

function M.refresh_loaded(fallback)
  local config = package.loaded["maxa.mcphub.native_servers.genai.config"]
  if not config then return end
  local current = M.get_initial_config(fallback)
  config.output_dir = current.output_dir
  config.defaults = vim.deepcopy(current.defaults)
  config.default_adapters = vim.deepcopy(current.default_adapters)
end

function M.write_persisted(medium, adapter)
  if not KEYS[medium] then return false, "medium must be one of: image, tts, video" end
  adapter = trim(adapter)
  if adapter == "" then return false, "adapter is required" end
  local key, lines, found = KEYS[medium], read_lines(), false
  for index, line in ipairs(lines) do
    if line:match("^%s*" .. key .. "%s*=") then lines[index], found = key .. "=" .. quote(adapter), true end
  end
  if not found then
    if #lines > 0 and trim(lines[#lines]) ~= "" then table.insert(lines, "") end
    table.insert(lines, key .. "=" .. quote(adapter))
  end
  local ok, err = pcall(vim.fn.writefile, lines, env_path())
  return ok, ok and nil or err
end

function M.persist_and_apply(medium, adapter, config)
  local ok, err = M.write_persisted(medium, adapter)
  if not ok then return false, err end
  if type(config) ~= "table" then return false, "genai config is not available" end
  config.default_adapters = config.default_adapters or {}
  config.default_adapters[medium] = trim(adapter)
  return true
end

function M.current(config)
  local result = vim.deepcopy((config and config.default_adapters) or {})
  for medium, value in pairs(M.read_persisted() or {}) do if trim(value) ~= "" then result[medium] = trim(value) end end
  return result
end

return M
