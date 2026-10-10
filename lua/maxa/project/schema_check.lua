local runtime_version_source = require("maxa.version")
local M = {}

local checked_roots = {}
local installed = false

local function trim(s)
  return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function find_project_root(bufnr)
  local start
  if type(bufnr) == "number" and bufnr > 0 then
    local name = vim.api.nvim_buf_get_name(bufnr)
    if name ~= "" then
      start = vim.fs.dirname(name)
    end
  end
  start = start or vim.uv.cwd() or vim.fn.getcwd(-1, -1)
  local root = vim.fs.root(start, { ".maxa", ".git" })
  return root or start
end

local function read_project_schema_version(project_root)
  local meta_path = project_root .. "/.maxa/_meta.yaml"
  local fd = io.open(meta_path, "r")
  if not fd then
    return 0, "missing-meta"
  end
  local found
  for line in fd:lines() do
    local raw = line:match("^%s*schema_version%s*:%s*(.-)%s*$")
    if raw ~= nil then
      raw = raw:gsub("#.*$", "")
      raw = trim(raw)
      found = tonumber(raw)
      break
    end
  end
  fd:close()
  if found == nil then
    return 0, "missing-version"
  end
  if found < 0 or found % 1 ~= 0 then
    return nil, "invalid-version"
  end
  return found, nil
end

function M.check_project(project_root)
  local runtime_root = runtime_version_source.runtime_root
  local runtime_path = runtime_version_source.path
  local runtime_value, runtime_err = runtime_version_source.read()
  local runtime_version = tonumber(runtime_value)
  if not runtime_version then
    return {
      status = "runtime-version-unavailable",
      project_root = project_root,
      runtime_root = runtime_root,
      runtime_version_path = runtime_path,
      error = runtime_err,
    }
  end
  local project_version, project_err = read_project_schema_version(project_root)
  if not project_version then
    return {
      status = "project-version-invalid",
      project_root = project_root,
      runtime_root = runtime_root,
      runtime_version = runtime_version,
      error = project_err,
    }
  end
  local status = "ok"
  if project_version < runtime_version then
    status = "project-upgrade-required"
  elseif project_version > runtime_version then
    status = "runtime-upgrade-required"
  end
  return {
    status = status,
    project_root = project_root,
    runtime_root = runtime_root,
    runtime_version = runtime_version,
    project_version = project_version,
    project_error = project_err,
  }
end

local function is_callable(value)
  if type(value) == "function" then
    return true
  end
  local mt = type(value) == "table" and getmetatable(value) or nil
  return type(mt) == "table" and type(mt.__call) == "function"
end

local function popup_lines(result)
  if result.status == "project-upgrade-required" then
    return {
      "当前项目 .maxa schema 版本低于 Maxa runtime。",
      string.format("project=%s, runtime=%s", tostring(result.project_version), tostring(result.runtime_version)),
      "",
      "按 Y 确认：稍后使用 project-admin 执行项目升级。",
      "按 q / Esc 取消：本次继续，但不要依赖旧项目知识结构。",
    }
  elseif result.status == "runtime-upgrade-required" then
    return {
      "当前项目 .maxa schema 版本高于 Maxa runtime 支持版本。",
      string.format("project=%s, runtime=%s", tostring(result.project_version), tostring(result.runtime_version)),
      "",
      "按 Y 确认：稍后升级 Maxa runtime。",
      "按 q / Esc 取消：本次继续，但 runtime 可能无法正确理解项目结构。",
    }
  elseif result.status == "project-version-invalid" then
    return {
      "当前项目 .maxa/_meta.yaml 中的 schema_version 非法。",
      string.format("runtime=%s", tostring(result.runtime_version)),
      "",
      "按 Y 确认：稍后修复项目 schema 元数据。",
      "按 q / Esc 取消。",
    }
  else
    return {
      "Maxa runtime schema version 文件缺失或非法。",
      tostring(result.runtime_version_path or ""),
      "",
      "按 Y 确认：稍后修复 Maxa runtime 版本文件。",
      "按 q / Esc 取消。",
    }
  end
end

local function show_result_confirm(result, opts)
  opts = opts or {}
  if result.status == "ok" then
    return false
  end
  local win_factory = opts.win_factory
  if win_factory == nil then
    local ok_snacks, snacks = pcall(require, "snacks")
    win_factory = ok_snacks and snacks and snacks.win or nil
  end
  if not is_callable(win_factory) then
    vim.notify(table.concat(popup_lines(result), "\n"), vim.log.levels.WARN, { title = "Maxa Schema Check" })
    return false
  end
  local win
  local confirmed = false
  local function close()
    if win and type(win.close) == "function" then
      win:close()
    end
  end
  local function confirm()
    confirmed = true
    close()
  end
  local function cancel()
    close()
  end
  win = win_factory({
    title = " Maxa Schema Check ",
    title_pos = "center",
    border = "rounded",
    backdrop = 60,
    width = 72,
    height = 8,
    enter = true,
    text = popup_lines(result),
    footer_keys = { "Y", "q", "<esc>" },
    keys = {
      Y = { "Y", confirm, desc = "确认" },
      q = { "q", cancel, desc = "取消" },
      esc = { "<esc>", cancel, desc = "取消" },
    },
    on_close = function()
      if confirmed then
        vim.notify("Maxa schema check acknowledged.", vim.log.levels.INFO, { title = "Maxa Schema Check" })
      end
    end,
    wo = {
      wrap = true,
      linebreak = true,
    },
    bo = {
      modifiable = false,
      filetype = "maxa_schema_check_confirm",
    },
  })
  return true
end

function M.check_once_for_project(project_root, opts)
  if checked_roots[project_root] then
    return checked_roots[project_root]
  end
  local result = M.check_project(project_root)
  checked_roots[project_root] = result
  show_result_confirm(result, opts)
  return result
end

function M.setup()
  if installed then
    return
  end
  installed = true
  local group = vim.api.nvim_create_augroup("MaxaProjectSchemaCheck", { clear = true })
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = { "MaxaAIChatCreated", "MaxaAIChatOpened" },
    callback = function(args)
      local data = type(args.data) == "table" and args.data or {}
      local bufnr = tonumber(data.bufnr) or tonumber(args.buf)
      local root = find_project_root(bufnr)
      if root and root ~= "" then
        M.check_once_for_project(vim.fs.normalize(root))
      end
    end,
  })
end

function M._popup_lines_for_test(result)
  return popup_lines(result)
end

function M._show_result_confirm_for_test(result, opts)
  return show_result_confirm(result, opts)
end

function M._reset_for_test()
  checked_roots = {}
  installed = false
end

return M
