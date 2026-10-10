local M = {}

local ALLOWED_FIELDS = {
  name = true,
  path = true,
  type = true,
  responsibility = true,
}

local function trim(value)
  return vim.trim(value or "")
end

local function strip_quotes(value)
  value = trim(value)
  local first, last = value:sub(1, 1), value:sub(-1)
  if #value >= 2 and ((first == '"' and last == '"') or (first == "'" and last == "'")) then
    return value:sub(2, -2)
  end
  return value
end

local function normalize_path(path)
  if vim.fn.isabsolutepath(path) ~= 1 then
    return nil
  end
  local normalized = vim.fs.normalize(vim.fn.fnamemodify(path, ":p"))
  return vim.uv.fs_realpath(normalized) or normalized
end

local function finish_definition(definitions, current)
  if not current then
    return true
  end
  for _, field in ipairs({ "name", "path", "type", "responsibility" }) do
    if trim(current[field]) == "" then
      return false
    end
  end
  if current.type ~= "main" and current.type ~= "child" then
    return false
  end
  definitions[#definitions + 1] = current
  return true
end

local function parse_definitions(lines)
  local definitions = {}
  local current
  local in_workspaces = false
  local saw_workspaces = false
  local version

  for _, line in ipairs(lines) do
    local stripped = trim(line)
    local top_level = line:match("^%S") ~= nil

    if top_level and in_workspaces then
      if not finish_definition(definitions, current) then
        return nil
      end
      current = nil
      in_workspaces = false
    end

    local parsed_version = top_level and stripped:match("^version:%s*(.+)$") or nil
    if parsed_version then
      if version ~= nil then
        return nil
      end
      version = strip_quotes(parsed_version)
    elseif top_level and stripped == "workspaces:" then
      if saw_workspaces then
        return nil
      end
      saw_workspaces = true
      in_workspaces = true
    elseif in_workspaces and stripped ~= "" and not stripped:match("^#") then
      local item = stripped
      if line:match("^  %- ") then
        if not finish_definition(definitions, current) then
          return nil
        end
        current = {}
        item = trim(item:sub(3))
      elseif not current or not line:match("^    ") then
        return nil
      end

      local key, value = item:match("^([^:]+):(.*)$")
      key = trim(key)
      if not key or not ALLOWED_FIELDS[key] or current[key] ~= nil then
        return nil
      end
      current[key] = strip_quotes(value)
    end
  end

  if in_workspaces and not finish_definition(definitions, current) then
    return nil
  end

  if version ~= "1" then
    return nil
  end

  local seen_paths = {}
  for _, definition in ipairs(definitions) do
    local normalized = normalize_path(definition.path)
    if not normalized or seen_paths[normalized] then
      return nil
    end
    seen_paths[normalized] = true
    definition.normalized_path = normalized
  end
  return definitions
end

local function xml_escape(value)
  return value
    :gsub("&", "&amp;")
    :gsub("<", "&lt;")
    :gsub(">", "&gt;")
    :gsub('"', "&quot;")
    :gsub("'", "&apos;")
end

function M.render(project_root)
  if type(project_root) ~= "string" or trim(project_root) == "" then
    return ""
  end
  local current_path = normalize_path(project_root)
  if not current_path then
    return ""
  end

  local config_path = vim.fs.joinpath(project_root, ".maxa", "workspaces.yml")
  local ok, lines = pcall(vim.fn.readfile, config_path)
  if not ok or type(lines) ~= "table" then
    return ""
  end
  local definitions = parse_definitions(lines)
  if not definitions then
    return ""
  end

  for _, definition in ipairs(definitions) do
    if definition.normalized_path == current_path then
      return string.format(
        '  <git_workspace type="%s" name="%s">\n    <responsibility>%s</responsibility>\n  </git_workspace>',
        definition.type,
        xml_escape(definition.name),
        xml_escape(definition.responsibility)
      )
    end
  end
  return ""
end

return M
