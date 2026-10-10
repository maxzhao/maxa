local M = {}

local smx_env = require("maxa.utils.env")

local function env(name, default)
  local value = smx_env.get(name)
  if value == nil or value == "" then
    return default
  end
  return value
end

local function truthy(value)
  value = tostring(value or ""):lower()
  return value == "1" or value == "true" or value == "yes" or value == "on"
end

local function defaults()
  return vim.deepcopy(require("maxa.config").runtime().telegram_bridge)
end

local state = defaults()

function M.setup(opts)
  opts = opts or {}
  local base = defaults()
  local overrides = {
    enabled = env("MAXA_TELEGRAM_BRIDGE_ENABLED") ~= nil and truthy(env("MAXA_TELEGRAM_BRIDGE_ENABLED")) or base.enabled,
    url = env("MAXA_TELEGRAM_BRIDGE_URL", base.url),
    token = env("MAXA_TELEGRAM_BRIDGE_TOKEN", base.token),
    poll_timeout = tonumber(env("MAXA_TELEGRAM_POLL_TIMEOUT", tostring(base.poll_timeout))) or base.poll_timeout,
  }
  state = vim.tbl_deep_extend("force", base, overrides, opts)
  state.url = tostring(state.url or base.url):gsub("/+$", "")
  return state
end

function M.get()
  if not state then
    return M.setup({})
  end
  return state
end

function M.is_enabled()
  return M.get().enabled == true
end

function M.project_root(cwd)
  cwd = cwd or vim.uv.cwd() or vim.fn.getcwd(-1, -1)
  if not cwd or cwd == "" then
    return nil
  end
  return vim.fs.root(cwd, { ".maxa" })
end

return M
