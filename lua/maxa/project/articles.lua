local M = {}

local PREVIEW_LIMIT = 20000

M.ROOTS = {
  { category = "report", badge = "[REPORT]", dir = "reports", label = "reports" },
  { category = "idea", badge = "[IDEA]", dir = "ideas", label = "ideas" },
  { category = "rule", badge = "[RULE]", dir = "rules", label = "rules" },
  { category = "research", badge = "[RESEARCH]", dir = "research", label = "research" },
}

local function normalize(path)
  if not path or path == "" then
    return nil
  end
  local normalized = tostring(path):gsub("\\", "/")
  normalized = normalized:gsub("/+$", "")
  return normalized ~= "" and normalized or "/"
end

local function joinpath(...)
  return vim.fs.joinpath(...)
end

local function stat_mtime(path)
  local stat = vim.uv.fs_stat(path)
  if not stat or not stat.mtime then
    return 0, 0
  end
  return stat.mtime.sec or 0, stat.mtime.nsec or 0
end

local function read_prefix(path, limit)
  local file = io.open(path, "r")
  if not file then
    return nil, false
  end
  local content = file:read(limit or PREVIEW_LIMIT) or ""
  local extra = file:read(1)
  file:close()
  return content, extra ~= nil
end

local function strip_quotes(value)
  value = vim.trim(value or "")
  if (value:sub(1, 1) == '"' and value:sub(-1) == '"') or (value:sub(1, 1) == "'" and value:sub(-1) == "'") then
    return value:sub(2, -2)
  end
  return value
end

local function parse_inline_list(value)
  local inner = value:match("^%[(.*)%]$")
  if not inner then
    return nil
  end
  local out = {}
  for part in inner:gmatch("[^,]+") do
    table.insert(out, strip_quotes(part))
  end
  return out
end

---@param content string
---@return table frontmatter, string body
function M.parse_frontmatter(content)
  content = content or ""
  local lines = vim.split(content, "\n", { plain = true })
  if lines[1] ~= "---" then
    return {}, content
  end

  local frontmatter = {}
  local current_key = nil
  local end_idx = nil
  for i = 2, #lines do
    local line = lines[i]
    if line == "---" then
      end_idx = i
      break
    end

    local list_value = line:match("^%s*%-%s+(.+)%s*$")
    if list_value and current_key then
      if type(frontmatter[current_key]) ~= "table" then
        frontmatter[current_key] = {}
      end
      table.insert(frontmatter[current_key], strip_quotes(list_value))
    else
      local key, value = line:match("^([%w_%-%.]+):%s*(.*)$")
      if key then
        current_key = key
        value = vim.trim(value or "")
        if value == "" then
          frontmatter[key] = {}
        else
          frontmatter[key] = parse_inline_list(value) or strip_quotes(value)
        end
      end
    end
  end

  if not end_idx then
    return {}, content
  end
  return frontmatter, table.concat(vim.list_slice(lines, end_idx + 1), "\n")
end

local function first_heading(body)
  for _, line in ipairs(vim.split(body or "", "\n", { plain = true })) do
    local heading = line:match("^%s*#+%s+(.+)%s*$")
    if heading and heading ~= "" then
      return heading
    end
  end
  return nil
end

local function read_metadata(path)
  local content = read_prefix(path, PREVIEW_LIMIT)
  if not content then
    return {}, ""
  end
  local fm, body = M.parse_frontmatter(content)
  return fm, body
end

---@param bufnr integer|nil
---@return string
function M.project_root(bufnr)
  local root
  if type(bufnr) == "number" and vim.api.nvim_buf_is_valid(bufnr) then
    root = vim.fs.root(bufnr, { ".maxa" })
  end

  if not root then
    local cwd = vim.uv.cwd() or vim.fn.getcwd(-1, -1)
    root = cwd and vim.fs.root(cwd, { ".maxa" }) or nil
    root = root or cwd
  end

  return normalize(root) or "."
end

local function relpath(path, root)
  local rel = vim.fs.relpath(root, path)
  if rel then
    return normalize(rel)
  end
  return normalize(path)
end

local function scan_files(dir, out)
  local handle = vim.uv.fs_scandir(dir)
  if not handle then
    return
  end

  while true do
    local name, typ = vim.uv.fs_scandir_next(handle)
    if not name then
      break
    end
    local abs = joinpath(dir, name)
    if typ == "directory" then
      scan_files(abs, out)
    elseif typ == "file" or typ == "link" then
      local stat = vim.uv.fs_stat(abs)
      if stat and stat.type == "file" then
        table.insert(out, abs)
      end
    end
  end
end

local function basename(path)
  return vim.fs.basename(path) or path
end

local function is_markdown(path)
  return path:match("%.md$") ~= nil
end

local function is_excluded_article_name(path)
  local name = basename(path):lower()
  return name == "index.md" or name == "log.md"
end

local function strip_md(path)
  return (path:gsub("%.md$", ""))
end

local function build_search_text(item)
  return table.concat({
    item.badge or "",
    item.category or "",
    item.title or "",
    item.display_name or "",
    item.category_rel_path or "",
    item.rel_path or "",
  }, " ")
end

local function make_item(root_def, abs_path, project_root, root_path)
  local rel = relpath(abs_path, project_root)
  local category_rel = relpath(abs_path, root_path)
  local fm, body = read_metadata(abs_path)
  local display = strip_md(category_rel)
  local item = {
    category = root_def.category,
    badge = root_def.badge,
    root_dir = root_def.dir,
    path = abs_path,
    rel_path = rel,
    category_rel_path = category_rel,
    display_name = display,
    title = fm.title or first_heading(body) or display,
    frontmatter = fm,
    file = abs_path,
  }
  local mtime, mtime_nsec = stat_mtime(abs_path)
  item.mtime = mtime
  item.mtime_nsec = mtime_nsec
  item.text = build_search_text(item)
  return item
end

---@param opts table|nil
---@return table[] items
function M.list_items(opts)
  opts = opts or {}
  local project_root = normalize(opts.project_root or M.project_root(opts.bufnr or 0)) or "."
  local items = {}

  for order, root_def in ipairs(M.ROOTS) do
    local root_path = joinpath(project_root, ".maxa", root_def.dir)
    local stat = vim.uv.fs_stat(root_path)
    if stat and stat.type == "directory" then
      local files = {}
      scan_files(root_path, files)
      for _, abs_path in ipairs(files) do
        if is_markdown(abs_path) and not is_excluded_article_name(abs_path) then
          local item = make_item(root_def, abs_path, project_root, root_path)
          item.root_order = order
          table.insert(items, item)
        end
      end
    end
  end

  table.sort(items, function(a, b)
    if a.mtime ~= b.mtime then
      return (a.mtime or 0) > (b.mtime or 0)
    end
    if a.mtime_nsec ~= b.mtime_nsec then
      return (a.mtime_nsec or 0) > (b.mtime_nsec or 0)
    end
    return a.rel_path < b.rel_path
  end)
  return items
end

---@param item table
---@return string
function M.format_entry(item)
  return string.format("%s %s  %s", item.badge or "[ARTICLE]", item.display_name or item.title or "", item.rel_path or "")
end

---@param item table
---@return string[]
function M.preview_lines(item)
  local lines = {
    "---",
    "category: " .. tostring(item.category or "unknown"),
    "path: " .. tostring(item.rel_path or item.path or ""),
    "title: " .. tostring(item.title or ""),
    "---",
    "",
  }

  local content, truncated = read_prefix(item.path, PREVIEW_LIMIT)
  if not content then
    table.insert(lines, "Article file not readable")
    return lines
  end
  if content == "" then
    table.insert(lines, "(empty article)")
    return lines
  end

  vim.list_extend(lines, vim.split(content, "\n", { plain = true }))
  if truncated then
    table.insert(lines, "")
    table.insert(lines, "... preview truncated ...")
  end
  return lines
end

---@param opts table|nil
---@return nil
function M.open_picker(opts)
  opts = opts or {}
  local project_root = normalize(opts.project_root or M.project_root(opts.bufnr or 0)) or "."
  local items = M.list_items({ project_root = project_root })
  if #items == 0 then
    vim.notify("[articles] No article files found under .maxa/{reports,ideas,rules,research}", vim.log.levels.INFO)
    return
  end

  require("snacks.picker").pick({
    title = "Articles",
    items = items,
    main = { file = false, float = true },
    format = function(item)
      return { { M.format_entry(item) } }
    end,
    transform = function(item)
      item.file = item.path
      item.text = item.text or item.rel_path
      return item
    end,
    preview = function(ctx)
      local item = ctx.item
      local buf_id = ctx.preview:scratch()
      vim.bo[buf_id].filetype = "markdown"
      vim.api.nvim_buf_set_lines(buf_id, 0, -1, false, M.preview_lines(item))
    end,
    confirm = function(picker, _)
      local selections = picker:selected({ fallback = true })
      if not selections or #selections == 0 then
        return
      end
      local selected = selections[1]
      picker:close()
      vim.cmd.edit(vim.fn.fnameescape(selected.path))
    end,
  })
end

return M
