-- Owned-source deletion for both MaxaConfig views; never delete runtime Native code.
local M = {}
local settings = require("maxa.project.settings")
local catalog = require("maxa.abilities.catalog")
local config = require("maxa.mcphub.utils.config_manager")

local function dependents(root, name)
  local result, seen = {}, {}
  -- Include global definitions hidden by a project replacement and disabled packages.
  for _, opts in ipairs({ { catalog_files = false }, { catalog_files = false, project_root = vim.fn.tempname() } }) do
    local list, err = catalog.list(root, opts)
    if not list then return nil, err end
    for _, ability in ipairs(list.abilities) do
      if ability.name ~= name and vim.tbl_contains(ability.dependencies, name) and not seen[ability.name] then
        result[#result + 1], seen[ability.name] = ability.name, true
      end
    end
  end
  table.sort(result)
  return result
end
M.dependents = dependents

local function sources(root, name)
  local effective, err = config.get_effective_catalog(root)
  if not effective then return nil, err end
  local global = vim.fn.stdpath("config")
  local result = {}
  for _, scope in ipairs({ "project", "global" }) do
    local parent = scope == "project" and (root .. "/.maxa/abilities") or (global .. "/abilities")
    local dir = parent .. "/" .. name
    local item = { scope = scope, name = name, root = root, paths = {}, definitions = {} }
    if vim.uv.fs_lstat(dir) then
      local stat = vim.uv.fs_lstat(dir)
      local real_parent, real_dir = vim.uv.fs_realpath(parent), vim.uv.fs_realpath(dir)
      if stat.type ~= "directory" or not real_parent or real_dir ~= real_parent .. "/" .. name then
        return nil, "Refusing to delete a non-directory or escaping ability path: " .. dir
      end
      item.package = dir
      item.paths[#item.paths + 1] = dir
    end
    for index, path in ipairs(effective.context.config_files) do
      if (scope == "global") == (index == 1) and vim.uv.fs_stat(path) then
        local raw, read_err = config.get_file_content_json(path)
        if not raw then return nil, read_err end
        local key = raw.servers and "servers" or "mcpServers"
        if (raw[key] or {})[name] then
          item.definitions[#item.definitions + 1] = { path = path, key = key }
          item.paths[#item.paths + 1] = path .. " [" .. key .. "." .. name .. "]"
        end
      end
    end
    if #item.paths > 0 then result[#result + 1] = item end
  end
  return result
end

function M.prepare(root, name, scope)
  root = settings.project_root(root)
  if not root or not catalog.valid_identifier(name) then return nil, "Invalid ability or project" end
  local effective, config_err = config.get_effective_catalog(root)
  if not effective then return nil, config_err end
  if (effective.servers[name] and effective.servers[name].is_native)
    or require("maxa.mcphub.native").is_native_server(name) then
    return nil, "Runtime Native abilities may be disabled, but cannot be deleted from this panel: " .. name
  end
  local reverse, err = dependents(root, name)
  if not reverse then return nil, err end
  if #reverse > 0 then return nil, "Remove dependent abilities first: " .. table.concat(reverse, ", ") end
  local choices, source_err = sources(root, name)
  if not choices then return nil, source_err end
  if not scope then return choices end
  for _, plan in ipairs(choices) do
    if plan.scope == scope then
      plan.fallback = #choices > 1
      -- Compare owning files again after the asynchronous confirmation.
      plan.fingerprint = {}
      local owned_paths = {}
      for _, entry in ipairs(plan.definitions) do owned_paths[#owned_paths + 1] = entry.path end
      if plan.package then
        owned_paths[#owned_paths + 1] = plan.package
        owned_paths[#owned_paths + 1] = plan.package .. "/SKILL.md"
        owned_paths[#owned_paths + 1] = plan.package .. "/ABILITY.yaml"
      end
      for _, actual in ipairs(owned_paths) do
        local stat = vim.uv.fs_lstat(actual)
        plan.fingerprint[#plan.fingerprint + 1] = { path = actual, real = vim.uv.fs_realpath(actual), ino = stat and stat.ino, mtime = stat and stat.mtime }
      end
      return plan
    end
  end
  return nil, "No deletable source"
end

function M.delete(plan)
  local fresh, err = M.prepare(plan.root, plan.name, plan.scope)
  if not fresh then return nil, err end
  if not vim.deep_equal(plan, fresh) then return nil, "Ability sources changed; confirm deletion again" end
  local originals = {}
  for _, entry in ipairs(plan.definitions) do
    local file, read_err = io.open(entry.path, "rb")
    if not file then return nil, read_err end
    originals[entry.path] = file:read("*a"); file:close()
  end
  local function restore_definitions()
    for path, text in pairs(originals) do
      local file = io.open(path, "wb")
      if file then file:write(text); file:close() end
    end
    config.refresh_config()
  end
  local staged
  if plan.package then
    staged = vim.fs.dirname(vim.fs.dirname(plan.package)) .. "/.ability-delete-" .. plan.name .. "-" .. tostring(vim.uv.hrtime())
    local ok, rename_err = vim.uv.fs_rename(plan.package, staged)
    if not ok then return nil, rename_err end
  end
  for _, entry in ipairs(plan.definitions) do
    local ok = config.update_server_config({ name = plan.name, config_source = entry.path, is_native = false }, nil)
    if not ok then
      restore_definitions()
      if staged then vim.uv.fs_rename(staged, plan.package) end
      return nil, "Failed to delete MCP definition: " .. entry.path
    end
  end
  if staged and vim.fn.delete(staged, "rf") ~= 0 then
    restore_definitions()
    vim.uv.fs_rename(staged, plan.package)
    return nil, "Failed to delete ability directory: " .. plan.package
  end
  vim.api.nvim_exec_autocmds("User", { pattern = "MaxaProjectSettingsChanged", modeline = false, data = { project_root = plan.root } })
  return true
end

function M.confirm(root, name, on_delete)
  local choices, err = M.prepare(root, name)
  if not choices then return vim.notify(tostring(err), vim.log.levels.WARN) end
  if #choices == 0 then return vim.notify("No deletable ability source", vim.log.levels.WARN) end
  local function confirm(choice)
    local plan, plan_err = M.prepare(root, name, choice.scope)
    if not plan then return vim.notify(tostring(plan_err), vim.log.levels.WARN) end
    local lines = { "Permanently delete ability " .. name .. " (" .. choice.scope .. ")?", "" }
    vim.list_extend(lines, plan.paths)
    lines[#lines + 1] = ""
    lines[#lines + 1] = "Deletion is irreversible. It will not cascade to other abilities or delete runtime source code."
    if plan.scope == "global" then
      lines[#lines + 1] = "Deleting a global source affects all projects. Private dependencies in other projects cannot be fully checked here."
    end
    if plan.fallback then lines[#lines + 1] = "Another source has the same name; it may become effective after deletion." end
    require("plenary.async").run(function()
      local accepted, cancelled = require("maxa.mcphub.utils.ui").confirm(lines, { min_width = 70, max_width = 100, default_option = "cancel" })
      if not accepted or cancelled then return end
      local ok, delete_err = M.delete(plan)
      if not ok then return vim.notify(tostring(delete_err), vim.log.levels.ERROR) end
      vim.notify("Deleted ability source: " .. name)
      if on_delete then on_delete() end
    end)
  end
  if #choices == 1 then return confirm(choices[1]) end
  vim.ui.select(choices, {
    prompt = "Select the source to permanently delete",
    format_item = function(item) return item.scope == "global" and "Global (affects all projects)" or "Current project" end,
  }, function(choice) if choice then confirm(choice) end end)
end
return M
