-- Project availability/visibility; connection lifecycle belongs to the MCP view.
local View = require("maxa.mcphub.ui.views.base")
local Text = require("maxa.mcphub.utils.text")
local NuiLine = require("maxa.mcphub.utils.nuiline")
local settings = require("maxa.project.settings")
local management = require("maxa.abilities.management")
local Project = setmetatable({}, { __index = View })
Project.__index = Project
local function suite_label(name) return (name:gsub("%-", " "):gsub("%f[%a]%l", string.upper)) end
local function source_label(ability)
  local labels = {}
  for _, layer in ipairs(ability.layers) do labels[#labels + 1] = layer.source == "project" and "Project package" or "Global package" end
  if ability.mcp then labels[#labels + 1] = "MCP" end
  return table.concat(labels, "+")
end
function Project:new(ui) return setmetatable(View:new(ui, "project"), self) end
function Project:selected()
  return self:get_line_info(vim.api.nvim_win_get_cursor(self.ui.window)[1])
end
function Project:before_enter()
  self.keymaps = {
    l = { desc = "Enable", action = function() self:action(true) end },
    h = { desc = "Disable", action = function() self:action(false) end },
    t = { desc = "Toggle", action = function() self:action() end },
    i = { desc = "Details", action = function() self:details() end },
    v = { desc = "Visibility", action = function() self:visibility() end },
    u = { desc = "Reset override", action = function() self:reset() end },
    d = { desc = "Delete", action = function() local kind, item = self:selected(); if kind == "ability" then management.confirm(self.ui.project_root, item.name, function() self:draw() end) end end },
    f = { desc = "Filter", action = function() vim.ui.input({ prompt = "Filter name/description/source/state/visibility (empty to clear): ", default = self.filter or "" }, function(value) if value ~= nil then self.filter = value:lower(); self:draw() end end) end },
    s = { desc = "Filter suite", action = function()
      local choices = { "All", "Ungrouped" }; vim.list_extend(choices, self.suite_names or {})
      vim.ui.select(choices, {
        prompt = "Ability suite",
        format_item = function(choice) return (choice == "All" or choice == "Ungrouped") and choice or suite_label(choice) end,
      }, function(choice) if choice then self.suite_filter = choice ~= "All" and choice or nil; self:draw() end end)
    end },
    r = { desc = "Refresh project", action = function() self:draw() end },
  }
  self:add_keymap_alias("<CR>", "l")
end
function Project:handle_cursor_move() View.handle_cursor_move(self) end
function Project:result(ok, err)
  if not ok then vim.notify(tostring(err), vim.log.levels.ERROR) else self:draw() end
end
function Project:action(enabled)
  local kind, item = self:selected()
  if not item then return end
  if kind == "ability" then
    if enabled == nil then enabled = not item.enabled end
    self:result(settings.set_ability(self.ui.project_root, item.name, enabled))
  elseif kind == "suite" then
    if enabled == nil then enabled = item.count < item.total end
    self:result(settings.set_suite(self.ui.project_root, item.name, enabled, self.abilities))
  end
end
function Project:visibility()
  local kind, item = self:selected()
  if kind ~= "ability" then return end
  local root, name = self.ui.project_root, item.name
  vim.ui.select({ "Inherit source", "global", "search", "hidden" }, { prompt = name .. " project visibility" }, function(value)
    if value then self:result(settings.set_visibility(root, name, value ~= "Inherit source" and value or nil)) end
  end)
end
function Project:reset()
  local kind, item = self:selected()
  if kind == "ability" then self:result(settings.reset_ability(self.ui.project_root, item.name)) end
end
function Project:details()
  local kind, item = self:selected()
  if kind ~= "ability" then return end
  self.expanded = self.expanded ~= item.name and item.name or nil
  self:draw()
end
function Project:render()
  local lines = self:render_header(false)
  local root = self.ui.project_root
  local function add(line, kind, context, highlight)
    lines[#lines + 1] = Text.pad_line(line, highlight)
    if kind then self:track_line(#lines, kind, context) end
  end
  local hl = Text.highlights
  add("Abilities / Suites", nil, nil, hl.header)
  add("Project availability does not load or connect capabilities.", nil, nil, hl.muted)
  local record, err = settings.read(root)
  if not record then add("Configuration unavailable: " .. tostring(err), nil, nil, hl.error); return lines end
  if record.missing then add("Project has no .maxa/_meta.yaml; initialize it first.", nil, nil, hl.warn); return lines end
  local discovered, discover_err = require("maxa.abilities.catalog").list(root, { catalog_files = false })
  if not discovered then add("Abilities unavailable: " .. tostring(discover_err), nil, nil, hl.error); return lines end
  self.abilities = discovered.abilities
  local suites = {}
  for _, ability in ipairs(self.abilities) do
    for _, name in ipairs(ability.suite) do
      suites[name] = suites[name] or { name = name, count = 0, total = 0 }
      local suite = suites[name]; suite.total = suite.total + 1
      if ability.enabled then suite.count = suite.count + 1 end
    end
  end
  self.suite_names = vim.tbl_keys(suites); table.sort(self.suite_names)
  local state = record.data.abilities or {}
  add("")
  add("Suites", nil, nil, hl.header)
  add("[Selected] protects overlapping memberships; counts show available members.", nil, nil, hl.muted)
  for _, name in ipairs(self.suite_names) do
    local suite = suites[name]
    local icon = suite.count == 0 and "[ ]" or (suite.count == suite.total and "[x]" or "[-]")
    local status_hl = suite.count == 0 and hl.muted or (suite.count == suite.total and hl.success or hl.warn)
    local line = NuiLine():append("  " .. icon .. " ", status_hl):append(suite_label(name), hl.text)
      :append(string.format(" (%d/%d)", suite.count, suite.total), status_hl)
    if vim.tbl_contains(state.enabled_suites or {}, name) then line:append(" [Selected]", hl.info) end
    add(line, "suite", { name = name, count = suite.count, total = suite.total, hint = "[l Enable all, h Disable, t Toggle]" })
  end
  add("")
  add("Ability                    Project state       Visibility   Source / Suites", nil, nil, hl.header)
  if (self.filter or "") ~= "" or self.suite_filter then add("Filter: " .. (self.filter or "") .. " / " .. (self.suite_filter or "All"), nil, nil, hl.info) end
  local shown = 0
  for _, ability in ipairs(self.abilities) do
    local explicit = (state.states or {})[ability.name]
    local status = ability.enabled and "Enabled" or "Disabled"
    local origin = explicit == nil and "default" or "override"
    local source = source_label(ability)
    local visibility_override = (state.visibility or {})[ability.name] ~= nil
    local visibility = ability.visibility .. (visibility_override and "*" or "")
    local haystack = (ability.name .. " " .. (ability.description or "") .. " " .. source .. " " .. status .. " " .. origin .. " " .. ability.visibility .. " " .. table.concat(ability.suite, " ")):lower()
    local suite_match = not self.suite_filter or (self.suite_filter == "Ungrouped" and #ability.suite == 0) or vim.tbl_contains(ability.suite, self.suite_filter)
    if suite_match and haystack:find(self.filter or "", 1, true) then
      shown = shown + 1
      local memberships = #ability.suite > 0 and (" {" .. table.concat(vim.tbl_map(suite_label, ability.suite), ", ") .. "}") or ""
      local status_hl = ability.enabled and hl.success or hl.muted
      local row = NuiLine():append("  " .. (ability.enabled and "[x]" or "[ ]") .. " ", status_hl)
        :append(string.format("%-25s ", ability.name), ability.enabled and hl.text or hl.muted)
        :append(status, status_hl):append("(" .. origin .. ")", explicit == nil and hl.muted or hl.info)
        :append(string.rep(" ", 20 - #status - #origin - 2))
        :append(string.format("%-11s  ", visibility), ability.visibility == "hidden" and hl.muted or hl.info)
        :append(source .. memberships, hl.muted)
      add(row, "ability", { name = ability.name, enabled = ability.enabled, hint = "[l Enable, h Disable, i Details, v Visibility, u Reset, d Delete]" })
      if self.expanded == ability.name then
        add("      " .. (ability.description or "No description"), nil, nil, hl.text)
        add("      Visibility: " .. ability.visibility .. "; source default: " .. ability.default_visibility .. "; * = project override", nil, nil, hl.info)
        for _, layer in ipairs(ability.layers) do add("      Package: " .. layer.root, nil, nil, hl.muted) end
        if ability.mcp then add("      MCP: " .. (ability.mcp.config_path or "Runtime Native registration"), nil, nil, hl.muted) end
        add("      Dependencies: " .. (#ability.dependencies > 0 and table.concat(ability.dependencies, ", ") or "None"), nil, nil, hl.muted)
        local reverse, reverse_err = management.dependents(root, ability.name)
        add("      Dependents: " .. (reverse and (#reverse > 0 and table.concat(reverse, ", ") or "None") or tostring(reverse_err)), nil, nil, reverse and hl.muted or hl.error)
        local chat = self.ui.invoking_chat
        if chat then
          local ready, ready_err = require("maxa.session.abilities").get_ready(chat, chat.opts.cwd or root, ability.name)
          add("      Invoking Chat: " .. (ready and "Loaded and ready" or (ready_err or "Not loaded")), nil, nil, ready and hl.success or hl.muted)
        end
      end
    end
  end
  add(string.format("Showing %d/%d; visibility: global=full routing, search=name index, hidden=unlisted (not disabled)", shown, #self.abilities), nil, nil, hl.muted)
  return lines
end
return Project
