-- filepath: lua/maxa/task_browser/state.lua
-- TaskAdmin browser state, CLI, and task-workspace context helpers.

local M = {}

M.STATUS_VALUES = { "pending", "in-progress", "done", "review", "deferred", "cancelled" }

function M.valid_tag(tag)
  return type(tag) == "string" and tag ~= "" and tag:match("^[A-Za-z0-9_-]+$") ~= nil
end

local function normalize(path)
  if type(path) ~= "string" or path == "" then
    return ""
  end
  return (vim.fn.fnamemodify(path, ":p"):gsub("\\", "/"):gsub("/+$", ""))
end

local function joinpath(...)
  return (table.concat({ ... }, "/"):gsub("/+", "/"))
end

function M.project_root(opts)
  opts = opts or {}
  return normalize(opts.project_root or vim.uv.cwd() or vim.fn.getcwd(-1, -1))
end

function M.tasks_root(opts)
  return joinpath(M.project_root(opts), ".maxa", "tasks")
end

function M.state_file(opts)
  opts = opts or {}
  return normalize(opts.state_file or joinpath(M.tasks_root(opts), "state.yaml"))
end

function M.get_active_tag(opts)
  opts = opts or {}
  local fallback = M.valid_tag(opts.fallback) and opts.fallback or "master"
  local ok, lines = pcall(vim.fn.readfile, M.state_file(opts))
  if not ok or type(lines) ~= "table" then
    return fallback
  end
  for _, line in ipairs(lines) do
    local tag = line:match("^%s*currentTag%s*:%s*['\"]?([^'\"#%s]+)['\"]?")
    if M.valid_tag(tag) then
      return tag
    end
  end
  return fallback
end

local function nvim_config_root()
  local ok, config = pcall(vim.fn.stdpath, "config")
  if ok and type(config) == "string" and config ~= "" then
    return normalize(config)
  end
  local runtime_root = require("maxa.version").runtime_root
  if runtime_root then
    return normalize(runtime_root)
  end
  return M.project_root()
end

function M.task_admin_root(opts)
  opts = opts or {}
  local candidates = {
    opts.task_admin_root,
    joinpath(nvim_config_root(), "abilities", "task-admin"),
    joinpath(vim.fn.expand("~/.config/nvim"), "abilities", "task-admin"),
    joinpath(M.project_root(opts), "abilities", "task-admin"),
  }
  for _, candidate in ipairs(candidates) do
    if type(candidate) == "string" and candidate ~= "" and vim.fn.isdirectory(candidate) == 1 then
      return normalize(candidate)
    end
  end
  return normalize(candidates[2])
end

function M.task_admin_script(name, opts)
  return joinpath(M.task_admin_root(opts), "scripts", name .. ".py")
end

local function task_admin_cmd(name, opts)
  local root = M.task_admin_root(opts)
  return {
    "uv",
    "run",
    "--project",
    root,
    "python",
    M.task_admin_script(name, opts),
    "--project-root",
    M.project_root(opts),
  }
end

function M.next_task_cmd(opts)
  opts = opts or {}
  local cmd = task_admin_cmd("next_task", opts)
  if opts.tag and opts.tag ~= "" then
    vim.list_extend(cmd, { "--tag", opts.tag })
  end
  return cmd
end

function M.get_next_task(opts)
  local result = vim.system(M.next_task_cmd(opts), { text = true }):wait()
  if result.code ~= 0 then
    return false, result.stderr ~= "" and result.stderr or result.stdout
  end
  local ok, decoded = pcall(vim.json.decode, result.stdout)
  if not ok then
    return false, "无法解析 next_task 输出: " .. tostring(result.stdout)
  end
  if not decoded.success then
    return false, decoded.error or decoded.message or result.stdout
  end
  return true, decoded.data or decoded
end

function M.switch_tag_cmd(tag, opts)
  if not M.valid_tag(tag) then
    return nil
  end
  local cmd = task_admin_cmd("manage_tag", opts)
  vim.list_extend(cmd, { "--action", "switch", "--name", tag })
  return cmd
end

function M.switch_tag(tag, opts)
  local cmd = M.switch_tag_cmd(tag, opts)
  if not cmd then
    return false, "tag 不能为空"
  end
  local result = vim.system(cmd, { text = true }):wait()
  if result.code == 0 then
    return true, result.stdout
  end
  return false, result.stderr ~= "" and result.stderr or result.stdout
end

function M.list_tags(opts)
  local ok, entries = pcall(vim.fn.readdir, M.tasks_root(opts))
  if not ok or type(entries) ~= "table" then
    return {}
  end
  local tags = {}
  for _, entry in ipairs(entries) do
    local full = joinpath(M.tasks_root(opts), entry)
    if M.valid_tag(entry) and vim.fn.isdirectory(full) == 1 then
      table.insert(tags, entry)
    end
  end
  table.sort(tags)
  return tags
end

function M.compare_ids(a, b)
  return (tonumber(a) or math.huge) < (tonumber(b) or math.huge)
end

function M.paths_for_id(tag, id, opts)
  local text = tostring(id or "")
  if not M.valid_tag(tag) or not text:match("^%d+$") or tonumber(text) < 1 then
    return nil
  end
  local normalized_id = tostring(tonumber(text))
  local task_dir = joinpath(M.tasks_root(opts), tag, string.format("task_%03d", tonumber(text)))
  return {
    tag = tag,
    id = normalized_id,
    task_dir = task_dir,
    meta_file = joinpath(task_dir, "_meta.yaml"),
    plan_file = joinpath(task_dir, "plan.md"),
    todo_file = joinpath(task_dir, "todo.md"),
  }
end

function M.context_from_path(path, opts)
  path = normalize(path or vim.api.nvim_buf_get_name(0))
  if path == "" then
    return nil
  end
  local root = normalize(M.tasks_root(opts))
  local prefix = root .. "/"
  local rel = path:sub(1, #prefix) == prefix and path:sub(#prefix + 1) or nil
  if not rel or rel == "" then
    return nil
  end
  local parts = vim.split(rel, "/", { plain = true, trimempty = true })
  if #parts ~= 3 then
    return nil
  end
  local tag, dir, filename = parts[1], parts[2], parts[3]
  local id_num = dir:match("^task_(%d+)$")
  if not id_num or dir ~= string.format("task_%03d", tonumber(id_num)) or (filename ~= "plan.md" and filename ~= "todo.md") then
    return nil
  end
  local result = M.paths_for_id(tag, tostring(tonumber(id_num)), opts)
  result.kind = filename == "plan.md" and "plan" or "todo"
  result.path = path
  return result
end

function M.context_from_buf(bufnr, opts)
  return M.context_from_path(vim.api.nvim_buf_get_name(bufnr or 0), opts)
end

return M
