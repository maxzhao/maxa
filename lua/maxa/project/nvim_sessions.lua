local uv = vim.uv or vim.loop

local M = {}

local HEADER_PREFIX = '" maxa-nvim-session: '
local STORE_PARTS = { ".maxa", "history", "nvim" }

local function notify(operation, message, level)
  vim.notify(string.format("[project_nvim_sessions] %s: %s", operation, message), level or vim.log.levels.INFO)
end

local function fail(operation, message)
  notify(operation, message, vim.log.levels.ERROR)
  error(string.format("project_nvim_sessions %s failed: %s", operation, message), 3)
end

local function missing_error(code)
  return code == "ENOENT"
end

local function canonical_global_cwd()
  local ok, cwd = pcall(vim.fn.getcwd, -1, -1)
  if not ok then
    return nil, "global cwd is unavailable: " .. tostring(cwd)
  end
  if type(cwd) ~= "string" or cwd == "" then
    return nil, "global cwd is unavailable"
  end

  local real, err = uv.fs_realpath(cwd)
  if not real then
    return nil, string.format("cannot resolve global cwd %s: %s", cwd, tostring(err))
  end
  return vim.fs.normalize(real)
end

local function resolve_scope()
  local cwd, cwd_err = canonical_global_cwd()
  if not cwd then
    return nil, cwd_err
  end

  local dir = cwd
  while true do
    local marker = vim.fs.joinpath(dir, ".maxa")
    local stat, err, code = uv.fs_stat(marker)
    if stat then
      if stat.type == "directory" then
        return {
          kind = "project",
          cwd = cwd,
          root = dir,
          store = vim.fs.joinpath(dir, unpack(STORE_PARTS)),
        }
      end
    elseif not missing_error(code) then
      return nil, string.format("cannot inspect %s: %s", marker, tostring(err))
    end

    local parent = vim.fs.dirname(dir)
    if not parent or parent == dir then
      break
    end
    dir = parent
  end

  return { kind = "ordinary", cwd = cwd }
end

local function operation_scope(operation)
  local scope, err = resolve_scope()
  if not scope then
    fail(operation, err)
  end
  return scope
end

local function trim_line_endings(value)
  return (tostring(value or ""):gsub("[\r\n]+$", ""))
end

local function run_git(root, args)
  local command = { "git" }
  vim.list_extend(command, args)
  local ok, proc = pcall(vim.system, command, {
    cwd = root,
    text = true,
    env = vim.tbl_extend("force", vim.fn.environ(), {
      GIT_OPTIONAL_LOCKS = "0",
      LANG = "C",
      LC_ALL = "C",
    }),
  })
  if not ok then
    return nil, "cannot start git: " .. tostring(proc)
  end
  local wait_ok, result = pcall(proc.wait, proc)
  if not wait_ok then
    return nil, "cannot wait for git: " .. tostring(result)
  end
  return result
end

local function git_error(result)
  local message = trim_line_endings(result.stderr)
  if message == "" then
    message = "exit code " .. tostring(result.code)
  end
  return message
end

local function resolve_slot(scope)
  local probe, probe_err = run_git(scope.root, { "rev-parse", "--is-inside-work-tree" })
  if not probe then
    return nil, probe_err
  end
  if probe.code ~= 0 then
    local stderr = trim_line_endings(probe.stderr)
    if probe.code == 128 and stderr:find("not a git repository", 1, true) then
      return {
        kind = "default",
        value = vim.NIL,
        filename = "default.vim",
        path = vim.fs.joinpath(scope.store, "default.vim"),
      }
    end
    return nil, "git repository probe failed: " .. git_error(probe)
  end
  if trim_line_endings(probe.stdout) ~= "true" then
    return {
      kind = "default",
      value = vim.NIL,
      filename = "default.vim",
      path = vim.fs.joinpath(scope.store, "default.vim"),
    }
  end

  local branch, branch_err = run_git(scope.root, { "symbolic-ref", "--quiet", "--short", "HEAD" })
  if not branch then
    return nil, branch_err
  end
  if branch.code == 0 then
    local name = trim_line_endings(branch.stdout)
    if name == "" then
      return nil, "git returned an empty branch name"
    end
    local filename = "branch-" .. vim.fn.sha256(name) .. ".vim"
    return {
      kind = "branch",
      value = name,
      filename = filename,
      path = vim.fs.joinpath(scope.store, filename),
    }
  end
  if branch.code ~= 1 then
    return nil, "git branch query failed: " .. git_error(branch)
  end

  local detached, detached_err = run_git(scope.root, { "rev-parse", "--verify", "HEAD" })
  if not detached then
    return nil, detached_err
  end
  if detached.code ~= 0 then
    return nil, "git detached HEAD query failed: " .. git_error(detached)
  end
  local commit = trim_line_endings(detached.stdout)
  if not commit:match("^[0-9a-f]+$") or (#commit ~= 40 and #commit ~= 64) then
    return nil, "git returned an invalid full commit id: " .. commit
  end
  local filename = "detached-" .. commit .. ".vim"
  return {
    kind = "detached",
    value = commit,
    filename = filename,
    path = vim.fs.joinpath(scope.store, filename),
  }
end

local function operation_slot(operation, scope)
  local slot, err = resolve_slot(scope)
  if not slot then
    fail(operation, string.format("cannot resolve Git session identity for %s: %s", scope.root, err))
  end
  return slot
end

local function metadata_for(slot)
  return {
    version = 1,
    kind = slot.kind,
    value = slot.value,
  }
end

local function ensure_store(store)
  local ok, result = pcall(vim.fn.mkdir, store, "p")
  if not ok then
    return nil, string.format("cannot create %s: %s", store, tostring(result))
  end
  local stat, err = uv.fs_stat(store)
  if not stat or stat.type ~= "directory" then
    return nil, string.format("cannot create %s: %s", store, tostring(err or "not a directory"))
  end
  return true
end

local function read_all(path)
  local file, open_err = io.open(path, "rb")
  if not file then
    return nil, tostring(open_err)
  end
  local body, read_err = file:read("*a")
  local closed, close_err = file:close()
  if not body then
    return nil, tostring(read_err)
  end
  if not closed then
    return nil, tostring(close_err)
  end
  return body
end

local function write_all(path, data)
  local file, open_err = io.open(path, "wb")
  if not file then
    return nil, tostring(open_err)
  end
  local ok, write_err = file:write(data)
  local close_ok, close_err = file:close()
  if not ok then
    return nil, tostring(write_err)
  end
  if not close_ok then
    return nil, tostring(close_err)
  end
  return true
end

local function temp_path(target)
  return string.format("%s.tmp-%d-%s", target, uv.os_getpid(), tostring(uv.hrtime()))
end

local function cleanup_temp(path)
  if path then
    pcall(uv.fs_unlink, path)
  end
end

local function project_save(scope)
  local slot = operation_slot("save", scope)
  local made, mkdir_err = ensure_store(scope.store)
  if not made then
    fail("save", mkdir_err)
  end

  local temporary = temp_path(slot.path)
  local previous_session = vim.v.this_session
  local ok, err = pcall(function()
    vim.cmd("mksession! " .. vim.fn.fnameescape(temporary))

    local body, read_err = read_all(temporary)
    if not body then
      error("cannot read generated session: " .. read_err, 0)
    end
    local header = HEADER_PREFIX .. vim.json.encode(metadata_for(slot)) .. "\n"
    local wrote, write_err = write_all(temporary, header .. body)
    if not wrote then
      error("cannot write session header: " .. write_err, 0)
    end

    local renamed, rename_err = uv.fs_rename(temporary, slot.path)
    if not renamed then
      error("cannot replace final session: " .. tostring(rename_err), 0)
    end
    temporary = nil
  end)
  cleanup_temp(temporary)
  if not ok then
    vim.v.this_session = previous_session
    fail("save", string.format("%s (%s)", tostring(err), slot.path))
  end
  vim.v.this_session = slot.path
end

local function parse_owned_filename(name)
  local digest = name:match("^branch%-([0-9a-f]+)%.vim$")
  if digest and #digest == 64 then
    return "branch", digest
  end
  local commit = name:match("^detached%-([0-9a-f]+)%.vim$")
  if commit and (#commit == 40 or #commit == 64) then
    return "detached", commit
  end
  if name == "default.vim" then
    return "default", nil
  end
end

local function read_record(path, name, stat)
  local filename_kind, filename_value = parse_owned_filename(name)
  if not filename_kind then
    return nil, "filename is not an owned slot"
  end

  local ok, lines = pcall(vim.fn.readfile, path, "", 1)
  if not ok then
    return nil, "cannot read header: " .. tostring(lines)
  end
  if type(lines) ~= "table" or type(lines[1]) ~= "string" then
    return nil, "missing metadata header"
  end
  if lines[1]:sub(1, #HEADER_PREFIX) ~= HEADER_PREFIX then
    return nil, "missing metadata header"
  end

  local encoded = lines[1]:sub(#HEADER_PREFIX + 1)
  local decoded_ok, metadata = pcall(vim.json.decode, encoded)
  if not decoded_ok or type(metadata) ~= "table" then
    return nil, "invalid metadata JSON"
  end
  if metadata.version ~= 1 or metadata.kind ~= filename_kind then
    return nil, "metadata version or kind does not match filename"
  end

  if filename_kind == "branch" then
    if type(metadata.value) ~= "string" or vim.fn.sha256(metadata.value) ~= filename_value then
      return nil, "branch metadata does not match filename"
    end
  elseif filename_kind == "detached" then
    if type(metadata.value) ~= "string" or metadata.value ~= filename_value then
      return nil, "detached metadata does not match filename"
    end
  elseif metadata.value ~= vim.NIL then
    return nil, "default metadata value must be null"
  end

  return {
    path = path,
    filename = name,
    kind = metadata.kind,
    value = metadata.value,
    stat = stat,
  }
end

local function mtime_parts(stat)
  local mtime = stat and stat.mtime or {}
  if type(mtime) == "number" then
    return mtime, 0
  end
  return tonumber(mtime.sec) or 0, tonumber(mtime.nsec) or 0
end

local function project_records(scope)
  local store_stat, store_err, store_code = uv.fs_stat(scope.store)
  if not store_stat then
    if missing_error(store_code) then
      return {}
    end
    return nil, string.format("cannot inspect %s: %s", scope.store, tostring(store_err))
  end
  if store_stat.type ~= "directory" then
    return nil, scope.store .. " is not a directory"
  end

  local scan, scan_err = uv.fs_scandir(scope.store)
  if not scan then
    return nil, string.format("cannot list %s: %s", scope.store, tostring(scan_err))
  end

  local records = {}
  while true do
    local name = uv.fs_scandir_next(scan)
    if not name then
      break
    end
    if parse_owned_filename(name) then
      local path = vim.fs.joinpath(scope.store, name)
      local stat, stat_err = uv.fs_lstat(path)
      if not stat then
        notify("list", string.format("skipping %s: %s", path, tostring(stat_err)), vim.log.levels.WARN)
      elseif stat.type ~= "file" then
        notify("list", "skipping non-regular slot " .. path, vim.log.levels.WARN)
      else
        local record, record_err = read_record(path, name, stat)
        if record then
          records[#records + 1] = record
        else
          notify("list", string.format("skipping invalid session %s: %s", path, record_err), vim.log.levels.WARN)
        end
      end
    end
  end

  table.sort(records, function(a, b)
    local a_sec, a_nsec = mtime_parts(a.stat)
    local b_sec, b_nsec = mtime_parts(b.stat)
    if a_sec ~= b_sec then
      return a_sec > b_sec
    end
    if a_nsec ~= b_nsec then
      return a_nsec > b_nsec
    end
    return a.filename < b.filename
  end)
  return records
end

local function records_or_fail(operation, scope)
  local records, err = project_records(scope)
  if not records then
    fail(operation, err)
  end
  return records
end

local function validate_exact(path)
  local name = vim.fs.basename(path)
  local stat, stat_err, stat_code = uv.fs_lstat(path)
  if not stat then
    if missing_error(stat_code) then
      return nil, "session does not exist"
    end
    return nil, "cannot inspect session: " .. tostring(stat_err)
  end
  if stat.type ~= "file" then
    return nil, "session is not a regular file"
  end
  return read_record(path, name, stat)
end

local function fire(persistence, event)
  local ok, err = pcall(persistence.fire, event)
  if not ok then
    return nil, tostring(err)
  end
  return true
end

local function source_record(persistence, record)
  local fired, fire_err = fire(persistence, "LoadPre")
  if not fired then
    notify("load", "LoadPre failed for " .. record.path .. ": " .. fire_err, vim.log.levels.ERROR)
    return false
  end

  local ok, source_err = pcall(vim.cmd, "source " .. vim.fn.fnameescape(record.path))
  if not ok then
    notify("load", "source failed for " .. record.path .. ": " .. tostring(source_err), vim.log.levels.ERROR)
    return false
  end

  local post, post_err = fire(persistence, "LoadPost")
  if not post then
    notify("load", "LoadPost failed for " .. record.path .. ": " .. post_err, vim.log.levels.ERROR)
    return false
  end
  return true
end

local function project_load(persistence, scope, opts)
  local record
  if opts and opts.last then
    local records = records_or_fail("load", scope)
    record = records[1]
    if not record then
      notify("load", "no project session in " .. scope.store)
      return
    end
  else
    local slot = operation_slot("load", scope)
    local record_err
    record, record_err = validate_exact(slot.path)
    if not record then
      if record_err ~= "session does not exist" then
        notify("load", "invalid session " .. slot.path .. ": " .. record_err, vim.log.levels.WARN)
      end
      notify("load", "no current session at " .. slot.path)
      return
    end
  end
  source_record(persistence, record)
end

local function record_label(record)
  if record.kind == "branch" then
    return "branch: " .. record.value
  end
  if record.kind == "detached" then
    return "detached: " .. record.value
  end
  return "default"
end

local function project_select(persistence, captured_scope)
  local records = records_or_fail("select", captured_scope)
  if #records == 0 then
    notify("select", "no project session in " .. captured_scope.store)
    return
  end

  vim.ui.select(records, {
    prompt = "Select a project session: ",
    format_item = function(record)
      local sec = mtime_parts(record.stat)
      return string.format("%s — %s", record_label(record), os.date("%Y-%m-%d %H:%M:%S", sec))
    end,
  }, function(selected)
    if not selected then
      return
    end

    local current, scope_err = resolve_scope()
    if not current then
      notify("select", scope_err, vim.log.levels.ERROR)
      return
    end
    if current.kind ~= "project" or current.root ~= captured_scope.root then
      notify("select", "global cwd ownership changed while the picker was open", vim.log.levels.WARN)
      return
    end

    local record, record_err = validate_exact(selected.path)
    if not record then
      notify(
        "select",
        string.format("selected session is unavailable or invalid: %s (%s)", selected.path, record_err),
        vim.log.levels.WARN
      )
      return
    end
    source_record(persistence, record)
  end)
end

function M.install(persistence)
  persistence = persistence or require("persistence")
  if persistence._maxa_project_nvim_sessions then
    return persistence
  end

  local originals = {}
  for _, name in ipairs({ "current", "save", "load", "list", "last", "select" }) do
    if type(persistence[name]) ~= "function" then
      error("project_nvim_sessions cannot install: persistence." .. name .. " is unavailable")
    end
    originals[name] = persistence[name]
  end

  persistence._maxa_project_nvim_sessions = { originals = originals }

  -- Upstream methods call each other through the public module table. Keep one
  -- ordinary operation delegated for its full method chain instead of routing
  -- those nested calls again. The selector callback needs the same treatment
  -- because vim.ui.select may invoke it asynchronously after select() returns.
  local ordinary_depth = 0
  local function delegate(name, ...)
    ordinary_depth = ordinary_depth + 1
    local results = { pcall(originals[name], ...) }
    ordinary_depth = ordinary_depth - 1
    if not results[1] then
      error(results[2], 0)
    end
    return unpack(results, 2)
  end

  local function delegate_select()
    local ui_select = vim.ui.select
    vim.ui.select = function(items, opts, callback)
      return ui_select(items, opts, function(...)
        ordinary_depth = ordinary_depth + 1
        local results = { pcall(callback, ...) }
        ordinary_depth = ordinary_depth - 1
        if not results[1] then
          error(results[2], 0)
        end
        return unpack(results, 2)
      end)
    end
    local results = { pcall(delegate, "select") }
    vim.ui.select = ui_select
    if not results[1] then
      error(results[2], 0)
    end
    return unpack(results, 2)
  end

  persistence.current = function(opts)
    if ordinary_depth > 0 then
      return originals.current(opts)
    end
    local scope = operation_scope("current")
    if scope.kind == "ordinary" then
      return delegate("current", opts)
    end
    return operation_slot("current", scope).path
  end

  persistence.save = function(...)
    if ordinary_depth > 0 then
      return originals.save(...)
    end
    local scope = operation_scope("save")
    if scope.kind == "ordinary" then
      return delegate("save", ...)
    end
    return project_save(scope)
  end

  persistence.load = function(opts)
    if ordinary_depth > 0 then
      return originals.load(opts)
    end
    local scope = operation_scope("load")
    if scope.kind == "ordinary" then
      return delegate("load", opts)
    end
    return project_load(persistence, scope, opts or {})
  end

  persistence.list = function()
    if ordinary_depth > 0 then
      return originals.list()
    end
    local scope = operation_scope("list")
    if scope.kind == "ordinary" then
      return delegate("list")
    end
    local records = records_or_fail("list", scope)
    return vim.tbl_map(function(record)
      return record.path
    end, records)
  end

  persistence.last = function()
    if ordinary_depth > 0 then
      return originals.last()
    end
    local scope = operation_scope("last")
    if scope.kind == "ordinary" then
      return delegate("last")
    end
    local records = records_or_fail("last", scope)
    return records[1] and records[1].path or nil
  end

  persistence.select = function()
    if ordinary_depth > 0 then
      return originals.select()
    end
    local scope = operation_scope("select")
    if scope.kind == "ordinary" then
      return delegate_select()
    end
    return project_select(persistence, scope)
  end

  return persistence
end

M._private = {
  header_prefix = HEADER_PREFIX,
  resolve_scope = resolve_scope,
  resolve_slot = resolve_slot,
  read_record = read_record,
}

return M
