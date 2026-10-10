local config = require("maxa.config")
local file_utils = require("maxa.utils.files")
local log = require("maxa.utils.log")
local utils = require("maxa.utils")
local yaml = require("maxa.utils.yaml")

local M = {}

local allowed_roles = {
  config.constants.USER_ROLE,
  config.constants.LLM_ROLE,
}

---Load all markdown prompts from a directory
---@param dir string
---@param context MaxaAI.BufferContext
---@return table
function M.load_from_dir(dir, context)
  local prompts = {}

  dir = vim.fs.normalize(dir)

  if not file_utils.is_dir(dir) then
    log:trace("Directory `%s` does not exist or is not a directory", dir)
    return prompts
  end

  -- Scan directory for .md files
  local handle = vim.uv.fs_scandir(dir)
  if not handle then
    return prompts
  end

  while true do
    local name, type = vim.uv.fs_scandir_next(handle)
    if not name then
      break
    end

    -- Only process .md files (including symlinks)
    if (type == "file" or type == "link") and name:match("%.md$") then
      local path = vim.fs.joinpath(dir, name)
      local ok, prompt = pcall(M.parse_file, path, context)

      if ok and prompt then
        prompt.name = prompt.name or vim.fn.fnamemodify(path, ":t:r")
        table.insert(prompts, prompt)
      end
    end
  end

  return prompts
end

---Parse a single markdown file into a prompt definition
---@param path string Path to the markdown file
---@param context MaxaAI.BufferContext
---@return table|nil
function M.parse_file(path, context)
  local content = file_utils.read(path)
  if not content or content == "" then return nil end

  local frontmatter, front_err = M.parse_frontmatter(content)
  if not frontmatter then
    log:warn("[Chat Prompts] Invalid metadata in `%s`: %s", path, front_err or "missing frontmatter")
    return nil
  end
  local prompts, prompt_err = M.parse_prompt(content, frontmatter)
  if not prompts then
    log:warn("[Chat Prompts] Invalid prompts in `%s`: %s", path, prompt_err or "unknown error")
    return nil
  end
  local saw_user = false
  for _, prompt in ipairs(prompts) do
    if prompt.role == config.constants.USER_ROLE then
      saw_user = true
    elseif not saw_user or frontmatter.insert ~= "inline" or frontmatter.snip then
      log:warn("[Chat Prompts] `%s`: llm must follow user, requires insert: inline and cannot enable snip", path)
      return nil
    end
  end

  return {
    context = frontmatter.context,
    description = frontmatter.description or "",
    name = frontmatter.name,
    insert = frontmatter.insert,
    snip = frontmatter.snip == true,
    path = path,
    prompts = prompts,
  }
end

---Extract YAML frontmatter from markdown content
---@param content string The full markdown file content
---@return table|nil Parsed frontmatter as a Lua table
function M.parse_frontmatter(content)
  local source = file_utils.normalize_content(content):match("^%-%-%-\n(.-)\n%-%-%-\n")
  if not source then return nil, "missing frontmatter" end
  local ok, frontmatter = pcall(yaml.decode_strict, source)
  if not ok or type(frontmatter) ~= "table" then return nil, tostring(frontmatter) end
  local allowed = { name = true, description = true, insert = true, context = true, snip = true }
  for key in pairs(frontmatter) do
    if not allowed[key] then return nil, "unsupported field " .. tostring(key) end
  end
  if type(frontmatter.name) ~= "string" or not frontmatter.name:match("^[-%w_:]+$") then
    return nil, "name must be a nonempty slash command identifier"
  end
  if frontmatter.description ~= nil and type(frontmatter.description) ~= "string" then
    return nil, "description must be a string"
  end
  if frontmatter.snip ~= nil and type(frontmatter.snip) ~= "boolean" then
    return nil, "snip must be a boolean"
  end
  local positions = { inline = true, split = true, next_line = true, append = true }
  frontmatter.insert = frontmatter.insert == nil and "inline" or frontmatter.insert
  if type(frontmatter.insert) ~= "string" or not positions[frontmatter.insert] then
    return nil, "insert must be inline, split, next_line or append"
  end
  if frontmatter.context ~= nil then
    if type(frontmatter.context) ~= "table" or not vim.islist(frontmatter.context) then
      return nil, "context must be a list of file/symbols entries"
    end
    for _, item in ipairs(frontmatter.context) do
      if type(item) ~= "table" or (item.type ~= "file" and item.type ~= "symbols") then
        return nil, "context type must be file or symbols"
      end
      local paths = type(item.path) == "string" and { item.path } or item.path
      if type(paths) ~= "table" or not vim.islist(paths) or #paths == 0 then
        return nil, "context path must be a string or nonempty string list"
      end
      for _, path in ipairs(paths) do
        if type(path) ~= "string" or path == "" then return nil, "context paths must be nonempty strings" end
      end
    end
  end
  return frontmatter
end

---Extract prompt definitions from markdown content
---@param content string The full markdown file content
---@param frontmatter table The parsed frontmatter
---@return table|nil prompts
---@return string|nil error
function M.parse_prompt(content, frontmatter)
  if not content then
    return nil
  end

  content = file_utils.normalize_content(content)
  local parser = vim.treesitter.get_string_parser(content, "markdown")
  local query = vim.treesitter.query.get("markdown", "chat")
  if not query then
    return nil
  end

  local tree = parser:parse()
  local root = tree[1]:root()
  local get_node_text = vim.treesitter.get_node_text --[[@as function]]

  local prompts = {}
  local current_role = nil
  local current_content = {}

  local function store_prompt()
    if current_role and #current_content > 0 then
      local prompt_content = vim.trim(table.concat(current_content, "\n"))
      if prompt_content ~= "" then
        table.insert(prompts, {
          role = current_role,
          content = prompt_content,
        })
      end
    end
  end

  for capture_id, node in query:iter_captures(root, content, 0, -1) do
    local capture_name = query.captures[capture_id]

    if capture_name == "role" then
      local role = vim.trim(get_node_text(node, content):lower())
      if not vim.tbl_contains(allowed_roles, role) then
        return nil, string.format("unsupported prompt role `%s`; valid roles: user, llm", role)
      end
      store_prompt()
      current_role = role
      current_content = {}
    elseif capture_name == "content" and current_role and vim.tbl_contains(allowed_roles, current_role) then
      table.insert(current_content, get_node_text(node, content))
    end
  end

  store_prompt()

  if #prompts == 0 then
    return nil, "no non-empty `## user` or `## llm` prompts found"
  end

  return prompts, nil
end

---Resolve scalar data placeholders without executing package code.
---@param item table The prompts structure with placeholders
---@param context MaxaAI.BufferContext
---@return nil
function M.resolve_placeholders(item, context)
  if item.snip then
    local args = { context = context, item = item }
    local function replace_context(content, choice)
      return content:gsub("%${([^{}]+)}", function(placeholder)
        if not placeholder:match("^context%.") and not placeholder:match("^item%.") then
          return "${" .. placeholder .. "}"
        end
        local value = args
        for _, part in ipairs(vim.split(placeholder, ".", { plain = true })) do
          if type(value) ~= "table" then value = nil; break end
          value = rawget(value, part)
        end
        local kind = type(value)
        if kind ~= "string" and kind ~= "number" and kind ~= "boolean" then
          log:warn("[Chat Prompts] Missing/non-scalar `${%s}` in `%s`", placeholder, item.path or item.name or "prompt")
          value = "${" .. placeholder .. "}"
        end
        -- LSP choices have different escape characters from ordinary text.
        -- Only replacement data is escaped; LuaSnip owns the template grammar.
        local specials = choice and "([,|])" or "([\\$}])"
        return (tostring(value):gsub(specials, "\\%1"))
      end)
    end
    for _, prompt in ipairs(item.prompts) do
      local source, parts, cursor = prompt.content, {}, 1
      while true do
        local first, last, open, choices, close = source:find("(%${%d+|)(.-)(|})", cursor)
        if not first then break end
        parts[#parts + 1] = replace_context(source:sub(cursor, first - 1), false)
        parts[#parts + 1] = open .. replace_context(choices, true) .. close
        cursor = last + 1
      end
      parts[#parts + 1] = replace_context(source:sub(cursor), false)
      prompt.content = table.concat(parts)
    end
    return item
  end
  local placeholders = utils.extract_all_placeholders(item.prompts)
  if #placeholders == 0 then
    return item
  end

  local args = {
    context = context,
    item = item,
  }

  local replacements = {}
  for _, placeholder in ipairs(placeholders) do
    local resolved = args
    for _, part in ipairs(vim.split(placeholder, ".", { plain = true })) do
      if type(resolved) ~= "table" then resolved = nil; break end
      resolved = rawget(resolved, part)
    end
    local kind = type(resolved)
    if kind == "string" or kind == "number" or kind == "boolean" then
      replacements[placeholder] = tostring(resolved)
    else
      log:warn("[Chat Prompts] Missing/non-scalar `${%s}` in `%s`", placeholder, item.path or item.name or "prompt")
    end
  end

  if vim.tbl_count(replacements) > 0 then
    utils.replace_placeholders(item.prompts, replacements)
  end

  return item
end

return M
