local M = {}

local PREVIEW_LIMIT = 20000

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

local function basename(path)
  return vim.fs.basename(path) or path
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

local function read_frontmatter(path)
  local content = read_prefix(path, PREVIEW_LIMIT)
  if not content then
    return {}, ""
  end
  return M.parse_frontmatter(content)
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

---@param project_root string|nil
---@return string
function M.specs_dir(project_root)
  return joinpath(project_root or M.project_root(0), ".maxa", "specs")
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

local function is_markdown(path)
  return path:match("%.md$") ~= nil
end

local function list_contains_changes(rel)
  return rel == ".maxa/specs/changes" or rel:match("^%.maxa/specs/changes/") ~= nil
end

local function title_for(path, fm)
  if fm.title and fm.title ~= "" then
    return fm.title
  end
  return basename(path)
end

local function change_id_from_rel(rel)
  return rel:match("^%.maxa/specs/changes/([^/]+)/")
end

local function capability_from_delta(rel, fm)
  if fm.capability and fm.capability ~= "" then
    return fm.capability
  end
  local capability = rel:match("^%.maxa/specs/changes/[^/]+/specs/(.+)/spec%.md$")
  if capability then
    return capability
  end
  return basename(rel)
end

local function append_search_parts(parts, value)
  if type(value) == "table" then
    for _, v in ipairs(value) do
      append_search_parts(parts, v)
    end
  elseif value and value ~= "" then
    table.insert(parts, tostring(value))
  end
end

local function build_search_text(item)
  local parts = {}
  append_search_parts(parts, item.rel_path)
  append_search_parts(parts, item.title)
  append_search_parts(parts, item.change_id)
  append_search_parts(parts, item.capability)
  append_search_parts(parts, item.status)
  append_search_parts(parts, item.merged_to)
  append_search_parts(parts, item.superseded_by)
  return table.concat(parts, " ")
end

local function make_item(kind, abs_path, rel_path, fm)
  fm = fm or {}
  local item = {
    kind = kind,
    path = abs_path,
    rel_path = rel_path,
    title = title_for(abs_path, fm),
    status = fm.status or "unknown",
    change_id = fm.change_id or change_id_from_rel(rel_path),
    capability = fm.capability,
    merged_to = fm.merged_to,
    superseded_by = fm.superseded_by,
    frontmatter = fm,
  }
  if kind == "delta_spec" then
    item.capability = capability_from_delta(rel_path, fm)
  end
  local mtime, mtime_nsec = stat_mtime(abs_path)
  item.mtime = mtime
  item.mtime_nsec = mtime_nsec
  item.text = build_search_text(item)
  item.file = abs_path
  return item
end

local function should_include_stable(rel, abs_path, fm)
  if list_contains_changes(rel) then
    return false
  end
  local name = basename(abs_path)
  if name == "index.md" or name == "log.md" then
    return false
  end
  return name == "spec.md" or fm.doc_role == "spec"
end

---@param opts table|nil
---@return table[] items
function M.list_items(opts)
  opts = opts or {}
  local project_root = normalize(opts.project_root or M.project_root(opts.bufnr or 0)) or "."
  local specs_dir = M.specs_dir(project_root)
  local stat = vim.uv.fs_stat(specs_dir)
  if not stat or stat.type ~= "directory" then
    return {}
  end

  local files = {}
  scan_files(specs_dir, files)

  local items = {}
  for _, abs_path in ipairs(files) do
    if is_markdown(abs_path) then
      local rel = relpath(abs_path, project_root)
      local fm = read_frontmatter(abs_path)
      if should_include_stable(rel, abs_path, fm) then
        table.insert(items, make_item("stable_spec", abs_path, rel, fm))
      elseif rel:match("^%.maxa/specs/changes/[^/]+/proposal%.md$") then
        table.insert(items, make_item("change", abs_path, rel, fm))
      elseif rel:match("^%.maxa/specs/changes/[^/]+/specs/.+/spec%.md$") then
        table.insert(items, make_item("delta_spec", abs_path, rel, fm))
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

local function list_lines(value)
  local out = {}
  if type(value) == "table" then
    for _, v in ipairs(value) do
      table.insert(out, "- " .. tostring(v))
    end
  elseif value and value ~= "" then
    table.insert(out, "- " .. tostring(value))
  end
  return out
end

local function status_guidance(item)
  local status = item.status or "unknown"
  if item.kind == "stable_spec" then
    return nil
  end
  if status == "accepted" then
    return "Accepted change: current behavior should usually be read from merged_to stable specs first."
  elseif status == "superseded" then
    return "Superseded change: follow superseded_by before using this older artifact."
  elseif status == "rejected" then
    return "Rejected change: historical/non-current unless explicitly revived."
  elseif status == "draft" then
    return "Draft change: proposed or in-progress; do not treat as accepted behavior."
  end
  return "Unknown lifecycle: frontmatter status was missing or unrecognized."
end

---@param item table
---@return string[]
function M.preview_lines(item)
  local lines = {
    "---",
    "type: " .. tostring(item.kind or "unknown"),
    "path: " .. tostring(item.rel_path or item.path or ""),
  }
  if item.status and item.status ~= "" then
    table.insert(lines, "status: " .. tostring(item.status))
  end
  if item.change_id then
    table.insert(lines, "change_id: " .. tostring(item.change_id))
  end
  if item.capability then
    table.insert(lines, "capability: " .. tostring(item.capability))
  end
  table.insert(lines, "---")
  table.insert(lines, "")

  local guidance = status_guidance(item)
  if guidance then
    table.insert(lines, "> " .. guidance)
    if item.status == "accepted" and item.merged_to then
      table.insert(lines, "")
      table.insert(lines, "merged_to:")
      vim.list_extend(lines, list_lines(item.merged_to))
    elseif item.status == "superseded" and item.superseded_by then
      table.insert(lines, "")
      table.insert(lines, "superseded_by:")
      vim.list_extend(lines, list_lines(item.superseded_by))
    end
    table.insert(lines, "")
  end

  local content, truncated = read_prefix(item.path, PREVIEW_LIMIT)
  if not content then
    table.insert(lines, "Spec file not readable")
    return lines
  end
  if content == "" then
    table.insert(lines, "(empty spec artifact)")
    return lines
  end

  vim.list_extend(lines, vim.split(content, "\n", { plain = true }))
  if truncated then
    table.insert(lines, "")
    table.insert(lines, "... preview truncated ...")
  end
  return lines
end

---@param item table
---@return string
function M.format_entry(item)
  if item.kind == "stable_spec" then
    return string.format("[SPEC %s] %s  %s", item.status or "unknown", item.title or "", item.rel_path or "")
  end
  local label = item.kind == "delta_spec" and "DELTA" or "CHANGE"
  local status = item.status or "unknown"
  local name = item.kind == "delta_spec" and string.format("%s/%s", item.change_id or "?", item.capability or "?")
    or (item.change_id or item.title or "?")
  return string.format("[%s %s] %s  %s", label, status, name, item.rel_path or "")
end

---@param opts table|nil
---@return nil
function M.open_picker(opts)
  opts = opts or {}
  local project_root = normalize(opts.project_root or M.project_root(opts.bufnr or 0)) or "."
  local specs_dir = M.specs_dir(project_root)
  local stat = vim.uv.fs_stat(specs_dir)
  if not stat or stat.type ~= "directory" then
    vim.notify("[specs] No .maxa/specs directory found", vim.log.levels.INFO)
    return
  end

  local items = M.list_items({ project_root = project_root })
  if #items == 0 then
    vim.notify("[specs] No spec files found under .maxa/specs", vim.log.levels.INFO)
    return
  end

  require("snacks.picker").pick({
    title = "Specs",
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
