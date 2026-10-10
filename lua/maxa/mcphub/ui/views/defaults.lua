-- Project-only default services, separate from Ability/suite management.
local View = require("maxa.mcphub.ui.views.base")
local Text = require("maxa.mcphub.utils.text")
local NuiLine = require("maxa.mcphub.utils.nuiline")
local settings = require("maxa.project.settings")
local Defaults = setmetatable({}, { __index = View })
Defaults.__index = Defaults
function Defaults:new(ui) return setmetatable(View:new(ui, "defaults"), self) end
function Defaults:before_enter()
  self.keymaps = {
    ["l"] = { desc = "Set default", action = function() self:action(false) end },
    ["h"] = { desc = "Inherit global", action = function() self:action(true) end },
    ["r"] = { desc = "Refresh project", action = function() self:draw() end },
  }
  self:add_keymap_alias("<CR>", "l")
end
function Defaults:action(clear)
  local kind, item = self:get_line_info(vim.api.nvim_win_get_cursor(self.ui.window)[1])
  if kind ~= "default" or not self.ui.project_root then return end
  local root = self.ui.project_root
  if not clear then return require("maxa.session.adapter_ui").select_type(item.name, nil, root) end
  local ok, err
  if item.name == "llm" then
    ok, err = require("maxa.session.default_adapter").clear({ scope = "project", project_root = root })
  else ok, err = settings.set_media(root, item.name, nil) end
  if not ok then vim.notify(tostring(err), vim.log.levels.ERROR) end
  self:draw()
end
function Defaults:render()
  local lines = self:render_header(false)
  local function add(text, highlight) lines[#lines + 1] = Text.pad_line(text, highlight) end
  local hl = Text.highlights
  add("Project Service Defaults", hl.header)
  add("")
  local record, err = settings.read(self.ui.project_root)
  if not record then add("Configuration unavailable: " .. tostring(err), hl.error); return lines end
  if record.missing then add("Project has no .maxa/_meta.yaml; initialize it first.", hl.warn); return lines end
  local values, value_err = require("maxa.session.adapter_ui").values(nil, self.ui.project_root)
  if not values then add("Service defaults unavailable: " .. tostring(value_err), hl.error); return lines end
  for _, name in ipairs({ "llm", "image", "tts", "video" }) do
    local value, scope = values[name]:match("^(.*)( %[[^%]]+%])$")
    value, scope = value or values[name], scope or ""
    local value_hl = value:find("[Unavailable]", 1, true) and hl.error
      or (value:find("Not configured", 1, true) and hl.warn or hl.info)
    add(NuiLine():append(string.format("  %-5s", name), hl.header):append(" — ", hl.muted)
      :append(value, value_hl):append(scope, scope == " [Project override]" and hl.info or hl.muted))
    self:track_line(#lines, "default", { name = name, hint = "[l Set default, h Inherit global]" })
  end
  add("")
  add("LLM defaults affect new Chats only; media defaults apply to subsequent calls.", hl.muted)
  return lines
end
return Defaults
