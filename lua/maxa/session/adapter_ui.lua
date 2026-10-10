-- Four-type default overview with captured global/project/session ownership.
local M = {}
local TYPES = { "llm", "image", "tts", "video" }
local settings = require("maxa.project.settings")

local function llm_model(chat)
  local model = chat.settings and chat.settings.model
    or (chat.adapter.model and chat.adapter.model.name) or chat.adapter.schema.model.default
  return type(model) == "function" and model(chat.adapter) or model
end

function M.values(chat, project_root)
  local fallback = require("maxa.presets").get_default("chat") or {}
  local llm, err
  if chat then llm = { adapter = chat.adapter.name, model = llm_model(chat) }
  else
    llm, err = require("maxa.session.default_adapter").current_scope(
      project_root and "project" or "global", project_root, fallback)
  end
  if not llm then return nil, err end
  local scope_root = project_root or (chat and chat.opts and (chat.opts.project_root or chat.opts.cwd))
  local media = require("maxa.mcphub.native_servers.genai.default_adapter").current(
    require("maxa.mcphub.native_servers.genai.config"))
  local session = require("maxa.mcphub.native_servers.genai.session_adapter")
  local registry = require("maxa.mcphub.native_servers.genai.capability_registry")
  local labels = { llm = string.format("%s / %s", llm.adapter or "Not configured", llm.model or "Not configured") }
  labels.llm = labels.llm .. (chat and " [Session]" or (project_root and (llm.inherited and " [Inherited global]" or " [Project override]") or " [Global]"))
  for _, medium in ipairs({ "image", "tts", "video" }) do
    local override = session.get(chat, medium)
    local project, project_err
    if scope_root then project, project_err = settings.media_adapter(scope_root, medium) end
    if project_err then return nil, project_err end
    local name = override or project or media[medium]
    local declaration = name and registry.get(name)
    local label = name or "Not configured"
    if declaration and declaration.formatted_name and declaration.formatted_name ~= name then
      label = declaration.formatted_name .. " (" .. name .. ")"
    end
    if name and not (declaration and declaration.capabilities[medium]) then label = label .. " [Unavailable]" end
    label = label .. (override and " [Session]" or (project and " [Project override]" or (scope_root and " [Inherited global]" or " [Global]")))
    labels[medium] = label
  end
  return labels
end

function M.select_type(medium, chat, project_root)
  if medium == "llm" then
    if chat then return require("maxa.interactions.chat.keymaps.change_adapter").callback(chat) end
    return require("maxa.session.default_adapter_ui").select_default({
      scope = project_root and "project" or "global", project_root = project_root, allow_scope_switch = false,
    })
  end
  return require("maxa.mcphub.native_servers.genai.default_adapter_ui").select_medium(medium, chat, project_root)
end

local function open(chat, project_root)
  local labels, err = M.values(chat, project_root)
  if not labels then vim.notify(tostring(err), vim.log.levels.ERROR); return end
  local scope = chat and "Session" or (project_root and ("Project: " .. project_root) or "Global")
  vim.ui.select(TYPES, {
    prompt = "Select Adapter Type [" .. scope .. "]", kind = "maxa_ai",
    format_item = function(medium) return medium .. " - " .. labels[medium] end,
  }, function(medium) if medium then M.select_type(medium, chat, project_root) end end)
end
function M.select_session(chat) return open(chat) end
function M.select_global() return open() end
function M.select_project(root)
  root = root or settings.context_root(vim.api.nvim_get_current_buf())
  if not root or not vim.uv.fs_stat(vim.fs.joinpath(root, ".maxa", "_meta.yaml")) then
    vim.notify("Current project has no .maxa/_meta.yaml; initialize it first", vim.log.levels.WARN)
    return
  end
  return open(nil, settings.project_root(root))
end
return M
