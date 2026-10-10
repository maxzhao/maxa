local M = {}

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

local function is_safe_drafts_dir(project_root, drafts_dir)
  local root = normalize(project_root)
  local dir = normalize(drafts_dir)
  if not root or not dir then
    return false
  end
  return dir == normalize(joinpath(root, ".maxa", "drafts"))
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
function M.drafts_dir(project_root)
  return joinpath(project_root or M.project_root(0), ".maxa", "drafts")
end

---@param project_root string|nil
---@return string drafts_dir
function M.ensure_drafts_dir(project_root)
  local dir = M.drafts_dir(project_root)
  vim.fn.mkdir(dir, "p")
  return dir
end

local function scan_dir(base_dir, rel_dir, out)
  local handle = vim.uv.fs_scandir(base_dir)
  if not handle then
    return
  end

  while true do
    local name, typ = vim.uv.fs_scandir_next(handle)
    if not name then
      break
    end

    local abs_path = joinpath(base_dir, name)
    local rel_path = rel_dir == "" and name or (rel_dir .. "/" .. name)

    if typ == "directory" then
      scan_dir(abs_path, rel_path, out)
    elseif typ == "file" or typ == "link" then
      local target_stat = vim.uv.fs_stat(abs_path)
      if target_stat and target_stat.type == "file" then
        local mtime_sec, mtime_nsec = stat_mtime(abs_path)
        table.insert(out, {
          path = abs_path,
          relative_inside_drafts = rel_path,
          rel_path = ".maxa/drafts/" .. rel_path,
          mtime = mtime_sec,
          mtime_nsec = mtime_nsec,
          size = target_stat.size or 0,
          type = typ,
        })
      end
    end
  end
end

---@param opts table|nil
---@return table[]
function M.list_files(opts)
  opts = opts or {}
  local project_root = opts.project_root or M.project_root(opts.bufnr or 0)
  local dir = M.drafts_dir(project_root)
  local stat = vim.uv.fs_stat(dir)
  if not stat or stat.type ~= "directory" then
    return {}
  end

  local items = {}
  scan_dir(dir, "", items)
  table.sort(items, function(a, b)
    if a.mtime == b.mtime then
      if a.mtime_nsec == b.mtime_nsec then
        return a.rel_path < b.rel_path
      end
      return a.mtime_nsec > b.mtime_nsec
    end
    return a.mtime > b.mtime
  end)
  return items
end

---@param opts table|nil
---@return table|nil
function M.latest_file(opts)
  local items = M.list_files(opts)
  return items[1]
end

local function format_relative_time(timestamp)
  local diff = os.time() - timestamp
  if diff < 0 then
    diff = 0
  end
  if diff < 60 then
    return diff .. "s"
  elseif diff < 3600 then
    return math.floor(diff / 60) .. "m"
  elseif diff < 86400 then
    return math.floor(diff / 3600) .. "h"
  end
  return math.floor(diff / 86400) .. "d"
end

local function format_size(bytes)
  if bytes < 1024 then
    return bytes .. "B"
  elseif bytes < 1024 * 1024 then
    return string.format("%.1fK", bytes / 1024)
  end
  return string.format("%.1fM", bytes / 1024 / 1024)
end

---@param item table
---@return string
local function format_entry(item)
  return string.format("%s  %s  %s", item.rel_path, format_size(item.size or 0), format_relative_time(item.mtime or 0))
end

---@param path string
---@return string[]
local function preview_lines(path)
  local file = io.open(path, "r")
  if not file then
    return { "Draft file not readable" }
  end
  local content = file:read(20000) or ""
  file:close()

  local lines = vim.split(content, "\n", { plain = true })
  if #lines == 0 or (#lines == 1 and lines[1] == "") then
    return { "(empty draft)" }
  end
  if #content >= 20000 then
    table.insert(lines, "")
    table.insert(lines, "... preview truncated ...")
  end
  return lines
end

---@param opts table|nil
---@return nil
function M.open_picker(opts)
  opts = opts or {}
  local project_root = opts.project_root or M.project_root(opts.bufnr or 0)
  M.ensure_drafts_dir(project_root)
  local items = M.list_files({ project_root = project_root })
  if #items == 0 then
    vim.notify("[drafts] No draft files found under .maxa/drafts", vim.log.levels.INFO)
    return
  end

  require("snacks.picker").pick({
    title = "Drafts",
    items = items,
    main = { file = false, float = true },
    format = function(item)
      return { { format_entry(item) } }
    end,
    transform = function(item)
      item.file = item.path
      item.text = item.rel_path
      return item
    end,
    preview = function(ctx)
      local item = ctx.item
      local buf_id = ctx.preview:scratch()
      vim.bo[buf_id].filetype = "markdown"
      vim.api.nvim_buf_set_lines(buf_id, 0, -1, false, preview_lines(item.path))
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

---@param opts table|nil
---@return integer deleted_files, string|nil err
function M.clear(opts)
  opts = opts or {}
  local project_root = opts.project_root or M.project_root(opts.bufnr or 0)
  local dir = M.ensure_drafts_dir(project_root)
  if not is_safe_drafts_dir(project_root, dir) then
    return 0, "refusing to clear unsafe drafts directory: " .. tostring(dir)
  end

  local files = M.list_files({ project_root = project_root })
  local handle = vim.uv.fs_scandir(dir)
  if not handle then
    return 0, nil
  end

  while true do
    local name = vim.uv.fs_scandir_next(handle)
    if not name then
      break
    end
    vim.fn.delete(joinpath(dir, name), "rf")
  end

  return #files, nil
end

---@return nil
function M.setup_commands()
  vim.api.nvim_create_user_command("MaxaDraftsClear", function(cmd)
    local project_root = M.project_root(0)
    local files = M.list_files({ project_root = project_root })
    if #files == 0 then
      M.ensure_drafts_dir(project_root)
      vim.notify("[drafts] No draft files to clear", vim.log.levels.INFO)
      return
    end

    if not cmd.bang then
      local choice = vim.fn.confirm(
        string.format("Clear %d draft file(s) under .maxa/drafts/?", #files),
        "&Yes\n&No",
        2
      )
      if choice ~= 1 then
        vim.notify("[drafts] Clear cancelled", vim.log.levels.INFO)
        return
      end
    end

    local deleted, err = M.clear({ project_root = project_root })
    if err then
      vim.notify("[drafts] " .. err, vim.log.levels.ERROR)
      return
    end
    vim.notify(string.format("[drafts] Cleared %d draft file(s)", deleted), vim.log.levels.INFO)
  end, {
    bang = true,
    desc = "Clear all files under the project .maxa/drafts directory",
  })
end

return M
