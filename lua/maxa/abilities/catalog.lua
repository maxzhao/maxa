local yaml = require("maxa.utils.yaml")

local M = {}

local VISIBILITIES = { global = true, search = true, hidden = true }
local ABILITY_FIELDS = {
  merge = true,
  visibility = true,
  triggers = true,
  dependencies = true,
  suite = true,
  include = true,
  exclude = true,
  executors = true,
  builtin_extensions = true,
  prompts = true,
  mcp = true,
}
local SKILL_FIELDS = {
  name = true,
  description = true,
  license = true,
  compatibility = true,
  metadata = true,
  ["allowed-tools"] = true,
}
local CONTROL_FILES = {
  ["SKILL.md"] = true,
  ["ABILITY.yaml"] = true,
  ["SYSTEM.md"] = true,
  ["USER_GUIDE.md"] = true,
}
local HARD_EXCLUDED_DIRS = {
  ["hooks"] = true,
  ["builtin"] = true,
  [".git"] = true,
  [".hg"] = true,
  [".svn"] = true,
  [".venv"] = true,
  ["venv"] = true,
  ["node_modules"] = true,
  ["__pycache__"] = true,
  [".pytest_cache"] = true,
  [".mypy_cache"] = true,
  [".ruff_cache"] = true,
  [".tox"] = true,
  [".nox"] = true,
  [".hypothesis"] = true,
  [".cache"] = true,
  ["htmlcov"] = true,
  ["tmp"] = true,
  ["temp"] = true,
}
local HARD_EXCLUDED_FILES = {
  ".env",
  ".env.*",
  ".DS_Store",
  "Thumbs.db",
  "desktop.ini",
  "*.pyc",
  "*.pyo",
  "*.swp",
  "*.swo",
  "*~",
  "*.tmp",
  "*.temp",
  "*.bak",
  "*.orig",
  "*.rej",
  "*.log",
  "*.pid",
  ".coverage",
  ".coverage.*",
  "coverage.xml",
}
local PUBLIC_REFERENCE_DIRS = {
  references = true,
  assets = true,
  templates = true,
  examples = true,
}
local EXECUTABLE_BITS = 73 -- 0111

local function trim(value)
  return vim.trim(tostring(value or ""))
end

local function read_file(path)
  local file, err = io.open(path, "rb")
  if not file then
    return nil, err
  end
  local content = file:read("*a") or ""
  file:close()
  return content
end

local function file_stat(path)
  return vim.uv.fs_stat(path)
end

local function is_file(path)
  local stat = file_stat(path)
  return stat and stat.type == "file"
end

local function canonical(path)
  return vim.uv.fs_realpath(path)
end

local function ensure_slash(path)
  return path:sub(-1) == "/" and path or (path .. "/")
end

local function contained(path, root)
  return path == root or path:sub(1, #ensure_slash(root)) == ensure_slash(root)
end

local function schema_error(path, message)
  return nil, string.format("%s: %s", path, message)
end

local function parse_document(path)
  local content, err = read_file(path)
  if not content then
    return nil, string.format("cannot read: %s", tostring(err))
  end
  local ok, decoded = pcall(yaml.decode_strict, content)
  if not ok then
    return nil, tostring(decoded)
  end
  if type(decoded) ~= "table" or (vim.islist or vim.tbl_islist)(decoded) then
    return nil, "expected one mapping document"
  end
  return decoded
end

local function split_skill_markdown(path)
  local content, err = read_file(path)
  if not content then
    return nil, nil, string.format("cannot read: %s", tostring(err))
  end
  content = content:gsub("\r\n", "\n"):gsub("\r", "\n")
  if content:sub(1, 4) ~= "---\n" then
    return nil, nil, "missing YAML frontmatter"
  end
  local stop_start, stop_end = content:find("\n%-%-%-\n", 4)
  if not stop_start then
    stop_start, stop_end = content:find("\n%-%-%-$", 4)
  end
  if not stop_start then
    return nil, nil, "unterminated YAML frontmatter"
  end
  return content:sub(5, stop_start - 1), content:sub(stop_end + 1)
end

local function valid_package_name(name)
  if type(name) ~= "string" or #name < 1 or #name > 64 then
    return false
  end
  if #name == 1 then
    return name:match("^[a-z0-9]$") ~= nil
  end
  return name:match("^[a-z0-9][a-z0-9-]*[a-z0-9]$") ~= nil and not name:find("--", 1, true)
end

function M.valid_identifier(identifier)
  return valid_package_name(identifier)
end

function M.valid_mcp_name(name)
  return valid_package_name(name) and name:match("^[a-z]") ~= nil
end

local function reject_null(value, field)
  if value == vim.NIL then
    return nil, field .. " must not be null"
  end
  return true
end

local function validate_string(value, field, min_length, max_length)
  local ok, err = reject_null(value, field)
  if not ok then
    return nil, err
  end
  if type(value) ~= "string" then
    return nil, field .. " must be a string"
  end
  local normalized = trim(value)
  if #normalized < (min_length or 0) then
    return nil, field .. " must not be blank"
  end
  if max_length and vim.fn.strchars(value) > max_length then
    return nil, string.format("%s must be at most %d characters", field, max_length)
  end
  return normalized
end

local function validate_string_list(value, field, opts)
  opts = opts or {}
  local ok, err = reject_null(value, field)
  if not ok then
    return nil, err
  end
  if type(value) ~= "table" or not (vim.islist or vim.tbl_islist)(value) then
    return nil, field .. " must be a list"
  end
  local result, seen = {}, {}
  for index, entry in ipairs(value) do
    local item, item_err = validate_string(entry, string.format("%s[%d]", field, index), 1)
    if not item then
      return nil, item_err
    end
    if opts.identifier and not M.valid_identifier(item) then
      return nil, string.format("%s[%d] is not a valid Ability identifier: %s", field, index, item)
    end
    if opts.english and (not item:match("[A-Za-z]") or item:find("[^\t\32-\126]")) then
      return nil, string.format("%s[%d] must be an English routing phrase", field, index)
    end
    if seen[item] then
      return nil, string.format("%s contains duplicate value %s", field, item)
    end
    seen[item] = true
    result[#result + 1] = item
  end
  return result
end

function M.parse_skill(path, expected_name)
  local frontmatter_text, body, split_err = split_skill_markdown(path)
  if not frontmatter_text then
    return schema_error(path, split_err)
  end
  local ok, frontmatter = pcall(yaml.decode_strict, frontmatter_text)
  if not ok then
    return schema_error(path, frontmatter)
  end
  if type(frontmatter) ~= "table" or (vim.islist or vim.tbl_islist)(frontmatter) then
    return schema_error(path, "frontmatter must be a mapping")
  end
  for key in pairs(frontmatter) do
    if not SKILL_FIELDS[key] then
      return schema_error(path, "unsupported Agent Skill frontmatter field " .. tostring(key))
    end
  end
  local name, name_err = validate_string(frontmatter.name, "name", 1, 64)
  if not name then
    return schema_error(path, name_err)
  end
  if not valid_package_name(name) then
    return schema_error(path, "name is not a valid package name: " .. name)
  end
  if expected_name and name ~= expected_name then
    return schema_error(path, string.format("name %s does not match directory identity %s", name, expected_name))
  end
  local description, description_err = validate_string(frontmatter.description, "description", 1, 1024)
  if not description then
    return schema_error(path, description_err)
  end
  if frontmatter.license ~= nil then
    local _, license_err = validate_string(frontmatter.license, "license", 0)
    if license_err then
      return schema_error(path, license_err)
    end
  end
  if frontmatter.compatibility ~= nil then
    local _, compatibility_err = validate_string(frontmatter.compatibility, "compatibility", 1, 500)
    if compatibility_err then
      return schema_error(path, compatibility_err)
    end
  end
  if frontmatter["allowed-tools"] ~= nil then
    local _, tools_err = validate_string(frontmatter["allowed-tools"], "allowed-tools", 0)
    if tools_err then
      return schema_error(path, tools_err)
    end
  end
  if frontmatter.metadata ~= nil then
    if frontmatter.metadata == vim.NIL or type(frontmatter.metadata) ~= "table" or (vim.islist or vim.tbl_islist)(frontmatter.metadata) then
      return schema_error(path, "metadata must be a string-to-string mapping")
    end
    for key, value in pairs(frontmatter.metadata) do
      if type(key) ~= "string" or type(value) ~= "string" then
        return schema_error(path, "metadata must be a string-to-string mapping")
      end
    end
  end
  return {
    name = name,
    description = description,
    body = vim.trim(body or ""),
    frontmatter = frontmatter,
    path = path,
  }
end

local function validate_relative_path(value, field)
  local path, err = validate_string(value, field, 1)
  if not path then
    return nil, err
  end
  if path:sub(1, 1) == "/" or path:find("\\", 1, true) or path:find("//", 1, true) then
    return nil, field .. " must be a normalized package-relative path"
  end
  for segment in path:gmatch("[^/]+") do
    if segment == "." or segment == ".." then
      return nil, field .. " must not contain . or .. segments"
    end
  end
  return path
end

local function validate_mcp_metadata(value)
  if type(value) ~= "table" or (vim.islist or vim.tbl_islist)(value) then
    return nil, "mcp must be a mapping"
  end
  for key in pairs(value) do
    if key ~= "overrides" then
      return nil, "mcp has unknown field " .. tostring(key)
    end
  end
  if value.overrides == nil then
    return nil, "mcp must contain overrides"
  end
  local overrides, err = validate_relative_path(value.overrides, "mcp.overrides")
  if not overrides then
    return nil, err
  end
  return { overrides = overrides }
end

local function validate_executor(entry, index)
  local field = string.format("executors[%d]", index)
  if entry == vim.NIL or type(entry) ~= "table" or (vim.islist or vim.tbl_islist)(entry) then
    return nil, field .. " must be a mapping"
  end
  for key in pairs(entry) do
    if key ~= "match" and key ~= "command" then
      return nil, field .. " has unknown field " .. tostring(key)
    end
  end
  if entry.match == nil or entry.command == nil then
    return nil, field .. " must contain exactly match and command"
  end
  local pattern, pattern_err = validate_string(entry.match, field .. ".match", 1)
  if not pattern then
    return nil, pattern_err
  end
  local regex_ok, regex = pcall(vim.regex, pattern)
  if not regex_ok or not regex then
    return nil, field .. ".match is not a valid Neovim regular expression: " .. tostring(regex)
  end
  local command, command_err = validate_string_list(entry.command, field .. ".command")
  if not command then
    return nil, command_err
  end
  if #command == 0 then
    return nil, field .. ".command must not be empty"
  end
  local has_script = false
  for _, token in ipairs(command) do
    if token:find("{script}", 1, true) then
      has_script = true
    end
    for placeholder in token:gmatch("{([^}]+)}") do
      if placeholder ~= "script" and placeholder ~= "root" then
        return nil, field .. ".command contains unsupported placeholder {" .. placeholder .. "}"
      end
    end
  end
  if not has_script then
    return nil, field .. ".command must include {script}"
  end
  return { match = pattern, command = command, regex = regex }
end

function M.parse_metadata(path)
  if not is_file(path) then
    return { provided = {} }
  end
  local document, parse_err = parse_document(path)
  if not document then
    return schema_error(path, parse_err)
  end
  for key in pairs(document) do
    if not ABILITY_FIELDS[key] then
      return schema_error(path, "unknown field " .. tostring(key))
    end
  end
  local result = { provided = {} }
  for key, value in pairs(document) do
    result.provided[key] = true
    local ok, null_err = reject_null(value, key)
    if not ok then
      return schema_error(path, null_err)
    end
  end
  if result.provided.merge then
    if type(document.merge) ~= "boolean" then
      return schema_error(path, "merge must be a boolean")
    end
    result.merge = document.merge
  end
  if result.provided.prompts then
    if type(document.prompts) ~= "boolean" then
      return schema_error(path, "prompts must be a boolean")
    end
    result.prompts = document.prompts
  end
  if result.provided.visibility then
    if type(document.visibility) ~= "string" or not VISIBILITIES[document.visibility] then
      return schema_error(path, "visibility must be global, search or hidden")
    end
    result.visibility = document.visibility
  end
  if result.provided.triggers then
    local value, err = validate_string_list(document.triggers, "triggers", { english = true })
    if not value then
      return schema_error(path, err)
    end
    result.triggers = value
  end
  if result.provided.dependencies then
    local value, err = validate_string_list(document.dependencies, "dependencies", { identifier = true })
    if not value then
      return schema_error(path, err)
    end
    result.dependencies = value
  end
  if result.provided.suite then
    local value, err = validate_string_list(document.suite, "suite", { identifier = true })
    if not value then return schema_error(path, err) end
    result.suite = value
  end
  if result.provided.include then
    local value, err = validate_string_list(document.include, "include")
    if not value then
      return schema_error(path, err)
    end
    result.include = value
  end
  if result.provided.exclude then
    local value, err = validate_string_list(document.exclude, "exclude")
    if not value then
      return schema_error(path, err)
    end
    result.exclude = value
  end
  if result.provided.executors then
    if type(document.executors) ~= "table" or not (vim.islist or vim.tbl_islist)(document.executors) then
      return schema_error(path, "executors must be a list")
    end
    result.executors = {}
    for index, entry in ipairs(document.executors) do
      local executor, err = validate_executor(entry, index)
      if not executor then
        return schema_error(path, err)
      end
      result.executors[#result.executors + 1] = executor
    end
  end
  if result.provided.builtin_extensions then
    local value, err = validate_string_list(document.builtin_extensions, "builtin_extensions")
    if not value then
      return schema_error(path, err)
    end
    local names = require("maxa.interactions.chat.tools.builtin").names
    for _, name in ipairs(value) do
      if not vim.tbl_contains(names, name) then
        return schema_error(path, "builtin_extensions contains unknown builtin " .. name)
      end
      if name == "multicall" then
        return schema_error(path, "builtin_extensions cannot extend multicall; it is a batch execution declaration")
      end
    end
    result.builtin_extensions = value
  end
  if result.provided.mcp then
    local value, err = validate_mcp_metadata(document.mcp)
    if not value then
      return schema_error(path, err)
    end
    result.mcp = value
  end
  return result
end

function M.parse_mcp_overrides(path)
  local document, parse_err = parse_document(path)
  if not document then
    return schema_error(path, parse_err)
  end
  for key in pairs(document) do
    if key ~= "tools" then
      return schema_error(path, "unknown field " .. tostring(key))
    end
  end
  if type(document.tools) ~= "table" or (vim.islist or vim.tbl_islist)(document.tools) or next(document.tools) == nil then
    return schema_error(path, "tools must be a non-empty mapping")
  end
  local result = { tools = {} }
  for tool_name, tool_override in pairs(document.tools) do
    if type(tool_name) ~= "string" or trim(tool_name) == "" then
      return schema_error(path, "tool names must be nonblank strings")
    end
    if type(tool_override) ~= "table" or (vim.islist or vim.tbl_islist)(tool_override) then
      return schema_error(path, "tools." .. tool_name .. " must be a mapping")
    end
    for key in pairs(tool_override) do
      if key ~= "description" and key ~= "parameters" then
        return schema_error(path, "tools." .. tool_name .. " has unknown field " .. tostring(key))
      end
    end
    local normalized = { parameters = {} }
    if tool_override.description ~= nil then
      local description, err = validate_string(tool_override.description, "tools." .. tool_name .. ".description", 1)
      if not description then
        return schema_error(path, err)
      end
      normalized.description = description
    end
    if tool_override.parameters ~= nil then
      if type(tool_override.parameters) ~= "table" or (vim.islist or vim.tbl_islist)(tool_override.parameters) then
        return schema_error(path, "tools." .. tool_name .. ".parameters must be a mapping")
      end
      for parameter_name, parameter_override in pairs(tool_override.parameters) do
        if type(parameter_name) ~= "string" or trim(parameter_name) == "" then
          return schema_error(path, "parameter names must be nonblank strings")
        end
        if type(parameter_override) ~= "table" or (vim.islist or vim.tbl_islist)(parameter_override) then
          return schema_error(path, string.format("tools.%s.parameters.%s must be a mapping", tool_name, parameter_name))
        end
        for key in pairs(parameter_override) do
          if key ~= "description" then
            return schema_error(path, string.format("tools.%s.parameters.%s has unknown field %s", tool_name, parameter_name, tostring(key)))
          end
        end
        local description, err = validate_string(
          parameter_override.description,
          string.format("tools.%s.parameters.%s.description", tool_name, parameter_name),
          1
        )
        if not description then
          return schema_error(path, err)
        end
        normalized.parameters[parameter_name] = { description = description }
      end
    end
    if normalized.description == nil and next(normalized.parameters) == nil then
      return schema_error(path, "tools." .. tool_name .. " must override a description or parameter")
    end
    result.tools[tool_name] = normalized
  end
  return result
end

local function scan_child_dirs(root)
  local names = {}
  local handle = vim.uv.fs_scandir(root)
  if not handle then
    return names
  end
  while true do
    local name, kind = vim.uv.fs_scandir_next(handle)
    if not name then
      break
    end
    if kind == "directory" then
      names[#names + 1] = name
    end
  end
  table.sort(names)
  return names
end

local function actual_mcp_catalog(project_root)
  local config_manager = require("maxa.mcphub.utils.config_manager")
  local catalog, err = config_manager.get_effective_catalog(project_root)
  if not catalog then
    return nil, err
  end
  local result = {}
  for name, config in pairs(catalog.servers or {}) do
    result[name] = {
      name = name,
      config = config,
      catalog = catalog,
      config_path = config.config_source,
    }
  end
  return result
end

local function mcp_catalog(project_root, opts)
  if opts and opts.mcp_catalog ~= nil then
    return opts.mcp_catalog
  end
  return actual_mcp_catalog(project_root)
end

local function skill_candidate(root, name, source)
  local dir = root .. "/" .. name
  local skill_path = dir .. "/SKILL.md"
  local stat, err, code = file_stat(skill_path)
  if not stat then
    if code == "ENOENT" then return nil end
    return nil, "Cannot inspect Ability source: " .. skill_path .. ": " .. tostring(err)
  end
  if stat.type ~= "file" then
    return nil, "Ability source is not a regular file: " .. skill_path
  end
  return { dir = dir, source = source, name = name }
end

local function parse_layer(candidate, expected_name)
  local skill, skill_err = M.parse_skill(candidate.dir .. "/SKILL.md", expected_name)
  if not skill then
    return nil, skill_err
  end
  local metadata, metadata_err = M.parse_metadata(candidate.dir .. "/ABILITY.yaml")
  if not metadata then
    return nil, metadata_err
  end
  local root = canonical(candidate.dir)
  if not root then
    return nil, candidate.dir .. ": cannot canonicalize Ability root"
  end
  return {
    dir = candidate.dir,
    root = root,
    source = candidate.source,
    skill = skill,
    metadata = metadata,
  }
end

local function effective_field(layers, field, default)
  for _, layer in ipairs(layers) do
    if layer.metadata.provided[field] then
      return layer.metadata[field], layer
    end
  end
  return default, nil
end

local function segment_pattern(segment)
  local output, index = "", 1
  while index <= #segment do
    local char = segment:sub(index, index)
    if char == "*" then
      output = output .. ".*"
    elseif char == "?" then
      output = output .. "."
    elseif char:match("[%(%)%.%%%+%-%[%]%^%$]") then
      output = output .. "%" .. char
    else
      output = output .. char
    end
    index = index + 1
  end
  return "^" .. output .. "$"
end

local function match_glob_segments(patterns, paths, pattern_index, path_index)
  if pattern_index > #patterns then
    return path_index > #paths
  end
  local pattern = patterns[pattern_index]
  if pattern == "**" then
    if match_glob_segments(patterns, paths, pattern_index + 1, path_index) then
      return true
    end
    return path_index <= #paths and match_glob_segments(patterns, paths, pattern_index, path_index + 1)
  end
  return path_index <= #paths
    and paths[path_index]:match(segment_pattern(pattern)) ~= nil
    and match_glob_segments(patterns, paths, pattern_index + 1, path_index + 1)
end

function M.matches_glob(path, glob)
  glob = trim(glob)
  if glob == "" then
    return false
  end
  local directory = glob:sub(-1) == "/"
  if directory then
    glob = glob:sub(1, -2)
  end
  local paths = vim.split(path, "/", { plain = true })
  local patterns = vim.split(glob, "/", { plain = true })
  if not glob:find("/", 1, true) then
    if directory then
      for index = 1, math.max(#paths - 1, 1) do
        if paths[index]:match(segment_pattern(glob)) then
          return true
        end
      end
      return false
    end
    return paths[#paths]:match(segment_pattern(glob)) ~= nil
  end
  if not directory then
    return match_glob_segments(patterns, paths, 1, 1)
  end
  for length = 1, #paths do
    local prefix = vim.list_slice(paths, 1, length)
    if match_glob_segments(patterns, prefix, 1, 1) and length < #paths then
      return true
    end
  end
  return false
end

local function matches_any(path, patterns)
  for _, pattern in ipairs(patterns or {}) do
    if M.matches_glob(path, pattern) then
      return true
    end
  end
  return false
end

local function is_hard_excluded(path)
  local top = path:match("^([^/]+)")
  return CONTROL_FILES[path] or HARD_EXCLUDED_DIRS[top] or matches_any(path, HARD_EXCLUDED_FILES)
end

local function is_public_reference(path)
  local top = path:match("^([^/]+)")
  return PUBLIC_REFERENCE_DIRS[top] == true
end

local function first_executor(executors, address)
  for _, executor in ipairs(executors or {}) do
    if executor.regex:match_str(address) then
      return executor
    end
  end
  return nil
end

local function collect_overlay_entries(dir, relative, root, owners)
  local handle = vim.uv.fs_scandir(dir)
  if not handle then
    return
  end
  while true do
    local name, kind = vim.uv.fs_scandir_next(handle)
    if not name then
      break
    end
    local child_relative = relative == "" and name or (relative .. "/" .. name)
    local path = dir .. "/" .. name
    local existing = owners[child_relative]
    if not existing then
      owners[child_relative] = { root = root, path = path, kind = kind }
      existing = owners[child_relative]
    end
    if kind == "directory" and not HARD_EXCLUDED_DIRS[name] then
      -- A higher-precedence non-directory owns the path and blocks the lower
      -- subtree. Higher directories still allow nonconflicting child overlay.
      local blocked = existing.path ~= path and existing.kind ~= "directory"
      if not blocked then
        collect_overlay_entries(path, child_relative, root, owners)
      end
    end
  end
end

local function classify_overlay(ability)
  local owners = {}
  for _, layer in ipairs(ability.layers) do
    collect_overlay_entries(layer.root, "", layer.root, owners)
  end
  local scripts, references, files, hidden_references = {}, {}, {}, {}
  for relative, owner in pairs(owners) do
    if not is_hard_excluded(relative) then
      local resolved = canonical(owner.path)
      local stat = resolved and file_stat(resolved) or nil
      if resolved and contained(resolved, owner.root) and stat and stat.type == "file" then
        local address = "/" .. relative
        local executor = first_executor(ability.executors, address)
        local executable = stat.mode and bit.band(stat.mode, EXECUTABLE_BITS) ~= 0
        local excluded = matches_any(relative, ability.exclude)
        local included = matches_any(relative, ability.include)
        local entry = {
          target = address,
          relative = relative,
          path = resolved,
          root = owner.root,
          executor = executor,
          executable = executable,
        }
        if excluded then
          -- `exclude` suppresses catalog disclosure only. Explicit `#ability[/path]`
          -- references remain readable, while excluded executables stay uncallable.
          if not executor and not executable then
            hidden_references[address] = entry
          end
        elseif executor or executable then
          files[address] = entry
          scripts[#scripts + 1] = entry
        elseif included or is_public_reference(relative) then
          files[address] = entry
          references[#references + 1] = entry
        else
          -- Default-hidden support files remain exact-readable without being
          -- disclosed by `load` catalogs or completion.
          hidden_references[address] = entry
        end
      end
    end
  end
  table.sort(scripts, function(a, b)
    return a.target < b.target
  end)
  table.sort(references, function(a, b)
    return a.target < b.target
  end)
  ability.overlay_owners = owners
  ability.files = files
  ability.hidden_references = hidden_references
  ability.scripts = scripts
  ability.references = references
end

local function hide_runtime_file(ability, path)
  for _, field in ipairs({ "files", "hidden_references" }) do
    for target, entry in pairs(ability[field] or {}) do
      if entry.path == path then
        ability[field][target] = nil
      end
    end
  end
  for _, field in ipairs({ "scripts", "references" }) do
    local visible = {}
    for _, entry in ipairs(ability[field] or {}) do
      if entry.path ~= path then
        visible[#visible + 1] = entry
      end
    end
    ability[field] = visible
  end
end

local function compose(identifier, candidates, mcp_source, expected_name, opts)
  local highest = candidates[1]
  if not highest and not mcp_source then
    return nil, "unknown Ability " .. identifier
  end
  if not highest then
    local server = mcp_source.config or {}
    local config = server.config or {}
    local description, description_err
    if config.description ~= nil then
      description, description_err = validate_string(config.description, "MCP Server " .. identifier .. ".description")
      if not description then
        return nil, description_err
      end
    end
    if (not description or description == "") and type(server.description) == "string" then
      description = trim(server.description)
    end
    description = description ~= "" and description or nil
    local triggers, triggers_err = {}, nil
    if config.triggers ~= nil then
      triggers, triggers_err = validate_string_list(config.triggers, "MCP Server " .. identifier .. ".triggers", { english = true })
      if not triggers then
        return nil, triggers_err
      end
    end
    local suites, suite_err = validate_string_list(config.suite == nil and {} or config.suite, "MCP Server " .. identifier .. ".suite", { identifier = true })
    if not suites then return nil, suite_err end
    return {
      name = identifier,
      description = description,
      roots = {},
      layers = {},
      skill = nil,
      mcp = mcp_source,
      merge = false,
      prompts = false,
      visibility = description and "global" or "search",
      triggers = triggers,
      dependencies = {},
      suite = suites,
      include = {},
      exclude = {},
      executors = {},
      scripts = {},
      references = {},
      files = {},
    }
  end

  local highest_layer, highest_err = parse_layer(highest, expected_name)
  if not highest_layer then
    return nil, highest_err
  end
  local merge = highest_layer.metadata.provided.merge and highest_layer.metadata.merge or false
  if mcp_source and not merge then
    return nil, string.format("Ability %s has Skill and MCP sources but its highest-precedence Skill does not declare merge: true", identifier)
  end

  local layers = { highest_layer }
  if merge then
    for index = 2, #candidates do
      local layer, layer_err = parse_layer(candidates[index], expected_name)
      if not layer then
        return nil, layer_err
      end
      layers[#layers + 1] = layer
    end
  end
  local mcp_metadata, mcp_layer = effective_field(layers, "mcp", nil)
  if mcp_metadata and not (merge and mcp_source) then
    return nil, "Ability " .. identifier .. " declares mcp overrides without a composed MCP source"
  end
  local ability = {
    name = identifier,
    roots = vim.tbl_map(function(layer)
      return layer.root
    end, layers),
    layers = layers,
    skill = highest_layer.skill,
    description = highest_layer.skill.description,
    mcp = merge and mcp_source or nil,
    merge = merge,
    visibility = effective_field(layers, "visibility", highest_layer.source == "project" and "global" or "search"),
    triggers = effective_field(layers, "triggers", {}),
    dependencies = effective_field(layers, "dependencies", {}),
    suite = effective_field(layers, "suite", {}),
    include = effective_field(layers, "include", {}),
    exclude = effective_field(layers, "exclude", {}),
    executors = effective_field(layers, "executors", {}),
    builtin_extensions = effective_field(layers, "builtin_extensions", {}),
    prompts = effective_field(layers, "prompts", false),
  }
  if not opts or opts.catalog_files ~= false then
    classify_overlay(ability)
  end
  if mcp_metadata then
    local configured_path = mcp_layer.root .. "/" .. mcp_metadata.overrides
    local resolved = canonical(configured_path)
    local stat = resolved and file_stat(resolved) or nil
    if not resolved or not contained(resolved, mcp_layer.root) or not stat or stat.type ~= "file" then
      return nil, "Ability " .. identifier .. " mcp.overrides is missing or outside its declaring root: " .. mcp_metadata.overrides
    end
    local overrides, override_err = M.parse_mcp_overrides(resolved)
    if not overrides then
      return nil, override_err
    end
    ability.mcp_overrides = overrides
    ability.mcp_overrides_path = resolved
    hide_runtime_file(ability, resolved)
  end
  return ability
end

local function roots(opts, project_root)
  return (opts and opts.global_root) or (vim.fn.stdpath("config") .. "/abilities"),
    (opts and opts.project_root) or (project_root .. "/.maxa/abilities")
end

local function resolve_package(name, project_root, opts, catalog)
  local global_root, project_abilities = roots(opts, project_root)
  local candidates = {}
  local project, project_err = skill_candidate(project_abilities, name, "project")
  if project_err then return nil, project_err end
  local global, global_err = skill_candidate(global_root, name, "global")
  if global_err then return nil, global_err end
  if project then
    candidates[#candidates + 1] = project
  end
  if global then
    candidates[#candidates + 1] = global
  end
  return compose(name, candidates, catalog[name], name, opts)
end

function M.resolve(identifier, project_root, opts)
  project_root = project_root or vim.fn.getcwd()
  if not M.valid_identifier(identifier) then
    return nil, "invalid Ability identifier " .. tostring(identifier)
  end
  local catalog, catalog_err = mcp_catalog(project_root, opts)
  if not catalog then
    return nil, tostring(catalog_err)
  end
  for name in pairs(catalog) do
    if not M.valid_mcp_name(name) then
      return nil, "configured MCP Server has invalid Ability identity " .. tostring(name)
    end
  end
  local ability, err = resolve_package(identifier, project_root, opts, catalog)
  if not ability then return nil, err end
  ability.default_visibility = ability.visibility
  local visibility, policy_err = require("maxa.project.settings").ability_visibility(project_root, identifier, ability.visibility)
  if not visibility then return nil, policy_err end
  ability.visibility = visibility
  return ability
end

-- Runtime-only fixed entrypoints; permission is read from the current package.
function M.resolve_builtin_extension(ability, tool_name)
  if not vim.tbl_contains(ability.builtin_extensions or {}, tool_name) then
    return nil
  end
  local relative = "builtin/" .. tool_name .. ".lua"
  for _, layer in ipairs(ability.layers or {}) do
    local directory = layer.root .. "/builtin"
    if vim.uv.fs_lstat(directory) then
      local resolved_dir = canonical(directory)
      local dir_stat = resolved_dir and file_stat(resolved_dir)
      if not resolved_dir or not contained(resolved_dir, layer.root) or not dir_stat or dir_stat.type ~= "directory" then
        return nil, "invalid or root-escaping builtin directory: " .. directory
      end
      local path = directory .. "/" .. tool_name .. ".lua"
      if vim.uv.fs_lstat(path) then
        local resolved = canonical(path)
        local stat = resolved and file_stat(resolved)
        if not resolved or not contained(resolved, layer.root) or not stat or stat.type ~= "file" then
          return nil, "invalid or root-escaping builtin extension: " .. path
        end
        return { path = resolved, root = layer.root }
      end
    end
  end
  return nil, "declared builtin extension is missing: " .. relative
end

function M.resolve_graph(identifier, project_root, opts)
  project_root = project_root or vim.fn.getcwd()
  local order, state, resolved = {}, {}, {}
  local function visit(name, stack)
    if state[name] == "done" then
      return true
    end
    if state[name] == "visiting" then
      stack[#stack + 1] = name
      return nil, "circular Ability dependency: " .. table.concat(stack, " -> ")
    end
    local ability, err = M.resolve(name, project_root, opts)
    if not ability then
      return nil, err
    end
    local allowed, policy_err = require("maxa.project.settings").check_ability(project_root, name)
    if not allowed then return nil, policy_err end
    state[name] = "visiting"
    stack[#stack + 1] = name
    for _, dependency in ipairs(ability.dependencies) do
      if dependency == name then
        return nil, "Ability " .. name .. " depends on itself"
      end
      local ok, dependency_err = visit(dependency, vim.list_slice(stack))
      if not ok then
        return nil, dependency_err
      end
    end
    state[name] = "done"
    resolved[name] = ability
    order[#order + 1] = name
    return true
  end
  local ok, err = visit(identifier, {})
  if not ok then
    return nil, err
  end
  return { order = order, abilities = resolved }
end

function M.list(project_root, opts)
  project_root = project_root or vim.fn.getcwd()
  local catalog, catalog_err = mcp_catalog(project_root, opts)
  if not catalog then
    return nil, tostring(catalog_err)
  end
  local global_root, project_abilities = roots(opts, project_root)
  local names = {}
  for name in pairs(catalog) do
    if not M.valid_mcp_name(name) then
      return nil, "configured MCP Server has invalid Ability identity " .. tostring(name)
    end
    names[name] = true
  end
  for _, root in ipairs({ global_root, project_abilities }) do
    for _, name in ipairs(scan_child_dirs(root)) do
      names[name] = true
    end
  end
  local sorted = vim.tbl_keys(names)
  table.sort(sorted)
  local result = { abilities = {}, paths = {} }
  for _, name in ipairs(sorted) do
    local ability, err = M.resolve(name, project_root, opts)
    if not ability then
      return nil, err
    end
    local enabled, policy_err = require("maxa.project.settings").ability_enabled(project_root, name)
    if enabled == nil then return nil, policy_err end
    ability.enabled = enabled
    result.abilities[#result.abilities + 1] = ability
    for _, reference in ipairs(ability.enabled and ability.references or {}) do
      result.paths[#result.paths + 1] = { name = name .. ":" .. reference.target, kind = "ability_reference" }
    end
    for _, script in ipairs(ability.enabled and ability.scripts or {}) do
      result.paths[#result.paths + 1] = { name = name .. ":" .. script.target, kind = "ability_script" }
    end
  end
  table.sort(result.paths, function(a, b)
    return a.name < b.name
  end)
  return result
end

function M.validate_file_target(target)
  if type(target) ~= "string" or target:sub(1, 1) ~= "/" then
    return nil, "Ability file target must begin with /"
  end
  if target == "/" or target:sub(-1) == "/" then
    return nil, "Ability file target contains an empty path segment"
  end
  for segment in target:gmatch("[^/]+") do
    if segment == "." or segment == ".." or segment == "" then
      return nil, "Ability file target contains an invalid path segment"
    end
  end
  if target:find("//", 1, true) then
    return nil, "Ability file target contains an empty path segment"
  end
  return true
end

-- One public content address; target bytes are opaque outside file lookup.
function M.parse_reference(reference)
  local name, target
  if type(reference) == "string" then
    name, target = reference:match("^#([^%[]+)%[(.+)%]$")
  end
  if not name or not M.valid_identifier(name) or vim.trim(target) == "" or target:find("[\r\n]") then
    return nil, nil, "invalid Ability reference; expected #<ability>[<nonblank-target>]"
  end
  return name, target
end

function M.format_reference(name, target)
  return "#" .. name .. "[" .. target .. "]"
end

-- Resolve one physical file without building/consulting disclosure or Chat state.
function M.resolve_file_reference(reference, project_root, opts)
  local name, target, parse_err = M.parse_reference(reference)
  if not name then
    return nil, parse_err
  end
  local valid, target_err = M.validate_file_target(target)
  if not valid then
    return nil, target_err
  end
  local resolve_opts = vim.tbl_extend("force", {}, opts or {}, { catalog_files = false })
  local ability, ability_err = M.resolve(name, project_root, resolve_opts)
  if not ability then
    return nil, ability_err
  end
  local directories = {}
  for _, root in ipairs(ability.roots) do
    directories[#directories + 1] = { path = root, root = root }
  end
  local segments = vim.split(target:sub(2), "/", { plain = true })
  for index, segment in ipairs(segments) do
    local candidates = {}
    for _, directory in ipairs(directories) do
      local path = directory.path .. "/" .. segment
      local stat, err, code = vim.uv.fs_lstat(path)
      if stat then
        candidates[#candidates + 1] = { path = path, root = directory.root, kind = stat.type }
        if #candidates == 1 and (index == #segments or stat.type ~= "directory") then
          break
        end
      elseif code ~= "ENOENT" then
        return nil, "Cannot inspect Ability file: " .. target .. ": " .. tostring(err)
      end
    end
    local owner = candidates[1]
    if not owner then
      return nil, "Ability file not found: " .. target, "not_found"
    end
    local resolved = canonical(owner.path)
    local stat = resolved and file_stat(resolved) or nil
    if not resolved or not contained(resolved, owner.root) or not stat then
      return nil, "Ability file is missing, replaced or outside its owning root: " .. target
    end
    if index == #segments then
      if stat.type ~= "file" then
        return nil, "Ability file target is not a regular file: " .. target
      end
      return { target = target, relative = target:sub(2), path = resolved, root = owner.root }
    end
    if stat.type ~= "directory" then
      return nil, "Ability file ancestor is not a directory: " .. target
    end
    directories = {}
    if owner.kind ~= "directory" then
      -- A symlink ancestor owns the subtree; never borrow a lower child.
      directories[1] = { path = resolved, root = owner.root }
    else
      for _, candidate in ipairs(candidates) do
        if candidate.kind == "directory" then
          directories[#directories + 1] = { path = candidate.path, root = candidate.root }
        end
      end
    end
  end
end

function M.resolve_file(ability, target, expected_kind)
  local ok, target_err = M.validate_file_target(target)
  if not ok then
    return nil, target_err
  end
  local entry = ability and ability.files and ability.files[target]
  if not entry and expected_kind ~= "script" then
    entry = ability and ability.hidden_references and ability.hidden_references[target]
  end
  if not entry then
    return nil, "Ability file is not cataloged: " .. target
  end
  if expected_kind == "script" and not (entry.executor or entry.executable) then
    return nil, "Ability file is not an executable entrypoint: " .. target
  end
  local resolved = canonical(entry.path)
  local stat = resolved and file_stat(resolved) or nil
  if not resolved or not contained(resolved, entry.root) or not stat or stat.type ~= "file" then
    return nil, "Ability file is missing, replaced or outside its owning root: " .. target
  end
  return vim.tbl_extend("force", {}, entry, { path = resolved })
end

---Return the side-effect-free effective Ability discovery list.
function M.scan_abilities(project_root)
  local catalog, err = M.list(project_root)
  if not catalog then
    vim.notify("[Maxa AI] Ability discovery failed: " .. tostring(err), vim.log.levels.ERROR)
    return {}
  end
  local result = {}
  local seen = {}
  local function append(ability)
    if seen[ability.name] then
      return
    end
    seen[ability.name] = true
    result[#result + 1] = {
      ability_name = ability.name,
      name = ability.name,
      description = ability.description,
      triggers = table.concat(ability.triggers or {}, ", "),
      visibility = ability.visibility,
      source = ability.layers[1] and ability.layers[1].source or "mcp",
      dir = ability.roots[1],
      roots = ability.roots,
      dependencies = ability.dependencies,
    }
  end
  for _, ability in ipairs(catalog.abilities or {}) do
    if ability.enabled ~= false then append(ability) end
  end
  table.sort(result, function(a, b) return a.name < b.name end)
  return result
end

return M
