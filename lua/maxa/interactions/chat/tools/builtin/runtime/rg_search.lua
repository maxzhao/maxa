-- Shared scope resolution and ripgrep execution for the Chat search/glob builtins.
local collector_type = require("maxa.interactions.chat.tools.builtin.runtime.output_collector")
local builtin_utils = require("maxa.interactions.chat.tools.builtin.runtime.utils")
local search_query = require("maxa.interactions.chat.tools.builtin.runtime.search_query")

local M = {}

local function windows_path(path)
  return path:match("^%a:[/\\]") or path:match("^\\\\")
end

local function wslpath(mode, path)
  local output = vim.fn.system({ "wslpath", mode, path })
  if vim.v.shell_error ~= 0 then
    return nil, "Cannot convert path with wslpath: " .. path .. ": " .. output
  end
  return (output:gsub("[\r\n]+$", ""))
end

local function scope_root(scope, context)
  local project = context and context.cwd
  if type(project) ~= "string" or project == "" then
    return nil, "Chat project root is unavailable."
  end
  if scope == nil or scope == "" or scope == "." then
    scope = project
  elseif scope:sub(1, 1) == "@" then
    local name = scope:sub(2)
    local ability, err = require("maxa.abilities.catalog").resolve(name, project)
    if not ability then
      return nil, "Cannot resolve Ability " .. scope .. ": " .. tostring(err)
    end
    if #ability.roots ~= 1 then
      return nil, "Ability " .. scope .. " needs exactly one filesystem root (found " .. #ability.roots .. ")."
    end
    scope = ability.roots[1]
  elseif windows_path(scope) then
    local converted, err = wslpath("-u", scope)
    if not converted then
      return nil, err
    end
    scope = converted
  elseif scope:sub(1, 1) ~= "/" then
    scope = project .. "/" .. scope
  end

  local root = vim.uv.fs_realpath(scope)
  local stat = root and vim.uv.fs_stat(root)
  if not stat or (stat.type ~= "file" and stat.type ~= "directory") then
    return nil, "Search scope is not an accessible file or directory: " .. scope
  end
  local win_root, err = wslpath("-w", root)
  if not win_root then
    return nil, err
  end
  local host = win_root:match("^%a:[/\\]") ~= nil
  local directory = stat.type == "file" and vim.fn.fnamemodify(root, ":h") or root
  local win_directory = host and wslpath("-w", directory) or nil
  if host and not win_directory then
    return nil, "Cannot convert Windows search directory: " .. directory
  end
  return {
    root = root,
    directory = directory,
    file = stat.type == "file",
    target = stat.type == "file" and vim.fn.fnamemodify(root, ":t") or ".",
    host = host,
    win_directory = win_directory,
  }
end

local function validate_array(value, name, required)
  if value == nil then
    if required then
      return nil, name .. " must be a nonempty string or array of strings."
    end
    return {}
  end
  if type(value) == "string" then
    value = { value }
  end
  if type(value) ~= "table" or not (vim.islist or vim.tbl_islist)(value) or (required and #value == 0) then
    return nil, name .. " must be " .. (required and "a nonempty" or "a") .. " string or array of strings."
  end
  for _, entry in ipairs(value) do
    if type(entry) ~= "string" or entry == "" then
      return nil, name .. " must contain only nonempty strings."
    end
  end
  return value
end

local function compile_globs(patterns)
  local compiled = {}
  for _, glob in ipairs(patterns) do
    local ok, matcher = pcall(vim.glob.to_lpeg, glob)
    if not ok then
      return nil, "Invalid file glob " .. glob .. ": " .. tostring(matcher)
    end
    local zero_star
    if glob:find("*", 1, true) and not glob:find("**", 1, true) then
      -- vim.glob.to_lpeg requires one character for '*'; file globs also match zero.
      local valid, regex = pcall(function()
        return vim.regex(vim.fn.glob2regpat(glob))
      end)
      if valid then
        zero_star = regex
      end
    end
    compiled[#compiled + 1] = {
      matcher = matcher,
      basename = not glob:find("/", 1, true),
      zero_star = zero_star,
      slashes = select(2, glob:gsub("/", "")),
    }
  end
  return compiled
end

local function matches_globs(compiled, path)
  for _, entry in ipairs(compiled) do
    local value = entry.basename and vim.fn.fnamemodify(path, ":t") or path
    if entry.matcher:match(value)
      or (entry.zero_star and entry.slashes == select(2, value:gsub("/", "")) and entry.zero_star:match_str(value))
    then
      return true
    end
  end
  return false
end

local function build_argv(kind, params, root)
  local query, patterns, err
  if kind == "search" then
    query, err = search_query.resolve(params, true)
    if not query then return nil, err end
  else
    patterns, err = validate_array(params.patterns, "patterns", false)
    if not patterns then return nil, err end
  end
  local includes
  includes, err = validate_array(params.include, "include", false)
  if not includes then
    return nil, err
  end
  local excludes
  excludes, err = validate_array(params.exclude, "exclude", false)
  if not excludes then
    return nil, err
  end
  local max_results = params.max_results
  if max_results ~= nil and (type(max_results) ~= "number" or max_results % 1 ~= 0 or max_results < 1) then
    return nil, "max_results must be a positive integer."
  end
  local selected, selected_err = compile_globs(kind == "glob" and patterns or includes)
  if not selected then
    return nil, selected_err
  end
  local rejected, rejected_err = compile_globs(excludes)
  if not rejected then
    return nil, rejected_err
  end
  local function allowed(path)
    return (#selected == 0 or matches_globs(selected, path)) and not matches_globs(rejected, path)
  end
  -- Positive rg -g flags override .gitignore; apply inclusion after rg instead.
  if kind == "search" and root.file and not allowed(root.target) then
    return false
  end
  local argv = { root.host and "runwingui" or "rg" }
  if root.host then
    vim.list_extend(argv, { "--cwd", root.win_directory, "rg" })
  end
  vim.list_extend(argv, { "--color=never" })
  if params.hidden then
    argv[#argv + 1] = "--hidden"
  end
  if params.no_ignore then
    argv[#argv + 1] = "--no-ignore"
  end
  if kind == "search" then
    local case = params.case or "sensitive"
    if case ~= "sensitive" and case ~= "insensitive" and case ~= "smart" then
      return nil, "case must be sensitive, insensitive, or smart."
    end
    local output = params.output or "matches"
    if output ~= "matches" and output ~= "files" then
      return nil, "output must be matches or files."
    end
    -- Equals-form expressions remain opaque to the Windows bridge parser.
    vim.list_extend(argv, search_query.rg_args(query, case))
    argv[#argv + 1] = output == "files" and "--files-with-matches" or "--json"
  else
    argv[#argv + 1] = "--files"
  end
  if not params.hidden and not root.file then
    -- Positive -g filters otherwise re-include dotfiles despite rg's default.
    argv[#argv + 1] = "--glob=!**/.*"
  end
  argv[#argv + 1] = "--"
  argv[#argv + 1] = root.target
  return argv, nil, allowed
end

local function relative_path(path)
  return (path:gsub("\\", "/"):gsub("^%./", ""))
end

local function display_path(path)
  -- Quote only paths that would break the path:line:text or one-path-per-line format.
  if path:find("[%c:]") then
    return vim.json.encode(path)
  end
  return path
end

local function scope_header(root, context)
  if root.directory ~= vim.uv.fs_realpath(context.cwd) then
    return "Scope: " .. root.directory .. "\n"
  end
  return ""
end

function M.run(kind, context, response)
  local params = {}
  for key, value in pairs(context.params or {}) do
    if value ~= vim.NIL then
      params[key] = value
    end
  end
  if params.scope ~= nil and type(params.scope) ~= "string" then
    return response:error("scope must be a string.")
  end
  local root, err = scope_root(params.scope, context)
  if not root then
    return response:error(err)
  end
  if kind == "glob" and root.file then
    return response:error("glob scope must be a directory: " .. root.root)
  end
  local argv, allowed
  argv, err, allowed = build_argv(kind, params, root)
  local prefix = scope_header(root, context)
  local unit = kind == "search" and params.output ~= "files" and "matches" or "files"
  if argv == false then
    return response:text(prefix .. "0 " .. unit):send()
  end
  if not argv then
    return response:error(err)
  end

  local collector = collector_type.new({ log_prefix = "maxa_" .. kind, max_chars = builtin_utils.MAX_OUTPUT_CHARS })
  local count, truncated, pending = 0, false, ""
  local preview = {}
  local stderr, stderr_chars = {}, 0
  local job_id, timer_id
  local function record(line)
    count = count + 1
    if params.max_results and count > params.max_results then
      truncated = true
      if job_id and vim.fn.jobwait({ job_id }, 0)[1] == -1 then
        vim.fn.jobstop(job_id)
      end
      return
    end
    if #preview < 2 then
      preview[#preview + 1] = vim.fn.strcharpart(line, 0, 240)
        .. (vim.fn.strchars(line) > 240 and "…" or "")
    end
    collector:append_lines("stdout", { line })
  end
  local function process_line(line)
    if line == "" or truncated then
      return
    end
    if kind == "search" and (params.output == nil or params.output == "matches") then
      local ok, event = pcall(vim.json.decode, line)
      if not ok or type(event) ~= "table" then
        err = "Cannot decode rg match output."
        return
      end
      if event.type == "match" then
        local path = event.data.path.text
        local text = event.data.lines.text
        if not path or not text then
          err = "rg returned a non-text path or match."
          return
        end
        path = relative_path(path)
        if allowed(path) then
          local content = text:gsub("[\r\n]+$", ""):gsub("\r", "\\r"):gsub("\n", "\\n")
          record(display_path(path) .. ":" .. event.data.line_number .. ":" .. content)
        end
      end
    else
      local path = relative_path(line)
      if allowed(path) then
        record(display_path(path))
      end
    end
  end
  local function append_stdout(data)
    if not data then
      return
    end
    for index, chunk in ipairs(data) do
      if index == 1 then
        pending = pending .. chunk
      else
        process_line(pending)
        pending = chunk
      end
    end
  end
  local options = {
    cwd = root.directory,
    stdout_buffered = false,
    stderr_buffered = false,
    on_stdout = function(_, data)
      append_stdout(data)
    end,
    on_stderr = function(_, data)
      for _, line in ipairs(data or {}) do
        if line ~= "" and stderr_chars < 2048 then
          local snippet = line:sub(1, 2048 - stderr_chars)
          stderr[#stderr + 1] = snippet
          stderr_chars = stderr_chars + #snippet
        end
      end
    end,
    on_exit = function(_, exit_code)
      if timer_id then
        vim.fn.timer_stop(timer_id)
      end
      if pending ~= "" then
        process_line(pending)
      end
      collector:close()
      if collector:error() then
        return response:error("Failed to write search results: " .. collector:error())
      end
      if err then
        return response:error(err)
      end
      if exit_code ~= 0 and not (exit_code == 1 and count == 0) and not truncated then
        return response:error("rg failed (" .. exit_code .. "): " .. table.concat(stderr, "\n"))
      end
      local suffix = truncated and string.format("[truncated: max_results=%d]", params.max_results) or nil
      if collector:exceeded() then
        local stats = collector:stats()
        local result = prefix .. table.concat(preview, "\n") .. "\n"
          .. string.format("[output exceeds limit: %d %s, %d chars; full results: %s]", math.min(count, params.max_results or count), unit, stats.total_chars, stats.log_file)
        if suffix then
          result = result .. "\n" .. suffix
        end
        return response:text(result):send()
      end
      local output = collector:stdout()
      local result = prefix .. (output ~= "" and output:gsub("\n$", "") or "0 " .. unit)
      if suffix then
        result = result .. "\n" .. suffix
      end
      return response:text(result):send()
    end,
  }
  job_id = vim.fn.jobstart(argv, options)
  if job_id <= 0 then
    return response:error((root.host and "runwingui" or "rg") .. " is not executable.")
  end
  timer_id = vim.fn.timer_start(300000, function()
    err = "rg search timed out after 300 seconds."
    vim.fn.jobstop(job_id)
  end)
end

return M
