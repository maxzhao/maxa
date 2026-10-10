-- Medium-first UI for changing runtime-local GenAI default adapters.
local registry = require("maxa.mcphub.native_servers.genai.capability_registry")
local state = require("maxa.mcphub.native_servers.genai.default_adapter")
local session = require("maxa.mcphub.native_servers.genai.session_adapter")
local M = {}
local MEDIA = { "image", "tts", "video" }
local CLEAR = { name = "Restore Project/Global Default", clear = true }
local PROJECT_CLEAR = { name = "Inherit global", clear = true }
local settings = require("maxa.project.settings")

local function config() return require("maxa.mcphub.native_servers.genai.config") end
local function select_opts(prompt, current)
  return {
    prompt = prompt,
    kind = "genai.nvim",
    format_item = function(item)
      local name = type(item) == "table" and item.name or item
      local display = type(item) == "table" and (item.formatted_name or name) or name
      if type(item) == "table" and item.clear then return "󰆴 " .. display end
      return (name == current and "* " or "  ") .. display
    end,
  }
end

local function select_adapter(medium, chat, project_root)
  local cfg = config()
  local root = project_root or (chat and chat.opts and (chat.opts.project_root or chat.opts.cwd))
  local project, project_err
  if root then project, project_err = settings.media_adapter(root, medium) end
  if project_err then vim.notify(tostring(project_err), vim.log.levels.ERROR); return end
  local current = session.get(chat, medium) or project or state.current(cfg)[medium]
  local adapters = registry.list(medium)
  if #adapters == 0 and not session.get(chat, medium) and not project_root then
    vim.notify("No adapter declares the genai " .. medium .. " capability", vim.log.levels.ERROR)
    return
  end
  table.sort(adapters, function(a, b)
    if a.name == current then return true end
    if b.name == current then return false end
    return a.name < b.name
  end)
  if chat then table.insert(adapters, 1, CLEAR)
  elseif project_root then table.insert(adapters, 1, PROJECT_CLEAR) end
  local scope = chat and "Session" or (project_root and ("Project: " .. project_root) or "Global")
  vim.ui.select(adapters, select_opts("Set genai " .. medium .. " adapter [" .. scope .. "]", current), function(item)
    if not item then return end
    if item.clear then
      local ok, err
      if project_root then ok, err = settings.set_media(project_root, medium, nil)
      else ok, err = session.set(chat, medium, nil) end
      vim.notify(ok and ("Restored inherited " .. medium .. " default") or tostring(err), ok and vim.log.levels.INFO or vim.log.levels.ERROR)
      return
    end
    local declaration = registry.get(item.name)
    if not declaration or not declaration.capabilities[medium] then
      vim.notify("Adapter does not declare the genai " .. medium .. " capability: " .. item.name, vim.log.levels.ERROR)
      return
    end
    local ok, err
    if chat then ok, err = session.set(chat, medium, item.name)
    elseif project_root then ok, err = settings.set_media(project_root, medium, item.name)
    else ok, err = state.persist_and_apply(medium, item.name, cfg) end
    if not ok then
      vim.notify("Failed to set the genai " .. medium .. " default adapter: " .. tostring(err), vim.log.levels.ERROR)
      return
    end
    vim.notify("Set " .. scope .. " genai " .. medium .. " adapter: " .. item.name, vim.log.levels.INFO)
  end)
end

function M.select_medium(medium, chat, project_root)
  if not vim.tbl_contains(MEDIA, medium) then return end
  return select_adapter(medium, chat, project_root)
end

function M.select_adapter()
  local current = state.current(config())
  local current_display = {}
  for _, medium in ipairs(MEDIA) do
    local name = current[medium]
    local declaration = name and registry.get(name) or nil
    current_display[medium] = declaration and declaration.formatted_name or name or "not configured"
  end
  vim.ui.select(MEDIA, {
    prompt = "Select genai medium",
    kind = "genai.nvim",
    format_item = function(medium)
      return string.format("%s - %s", medium, current_display[medium])
    end,
  }, function(medium)
    if medium then select_adapter(medium) end
  end)
end

return M
