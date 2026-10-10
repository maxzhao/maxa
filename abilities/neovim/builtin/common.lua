-- Package-local preparation and cooperative LSP request lifecycle. No windows/writes.
local M = {}
local bridge = require("maxa.interactions.chat.tools.builtin.runtime.async_cancel_bridge")
M.TIMEOUT_MS = 10000
function M.canonical(path)
  local resolved = path and vim.uv.fs_realpath(path)
  return resolved and vim.fs.normalize(resolved)
end
function M.within(path, root)
  return path == root or path:sub(1, #root + 1) == root .. "/"
end
function M.label(path, root)
  return M.within(path, root) and path:sub(#root + 2) or path
end
function M.check_file(path)
  local basename = vim.fs.basename(path)
  if basename == ".env" or basename:match("^%.env%.") then error("environment files are not LSP targets") end
  local stat = vim.uv.fs_stat(path)
  if not stat or stat.type ~= "file" then error("LSP file is not accessible: " .. path) end
end
function M.local_uri(uri)
  if type(uri) ~= "string" or not uri:match("^file:///") or uri:find("[?#]") then return nil end
  local ok, path = pcall(vim.uri_to_fname, uri)
  if not ok or path:find("%z") then return nil end
  path = M.canonical(path)
  if not path then return nil end
  local valid = pcall(M.check_file, path)
  return valid and path or nil
end
function M.buffer(path)
  local buf = vim.fn.bufnr(path)
  if buf >= 0 and vim.api.nvim_buf_is_loaded(buf) then return buf end
  for _, candidate in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(candidate) and M.canonical(vim.api.nvim_buf_get_name(candidate)) == path then return candidate end
  end
  return buf
end
function M.filetype(path)
  local buf = M.buffer(path)
  if buf >= 0 and vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].filetype ~= "" then return vim.bo[buf].filetype end
  return vim.filetype.match({ filename = path })
end
function M.target(file, cwd)
  local root = M.canonical(cwd)
  if not root then error("Chat project root is unavailable") end
  local absolute = file:sub(1, 1) == "/" or file:match("^%a:[/\\]")
  local path = M.canonical(absolute and file or root .. "/" .. file)
  if not path then error("LSP file is not accessible: " .. file) end
  M.check_file(path)
  local ft = M.filetype(path)
  if not ft or ft == "" then error("cannot identify file language: " .. file) end
  local buf = M.buffer(path)
  local loaded = buf >= 0 and vim.api.nvim_buf_is_loaded(buf) and not vim.b[buf].maxa_neovim_request_leases
  local lines = loaded and vim.api.nvim_buf_get_lines(buf, 0, -1, false) or vim.fn.readfile(path)
  if #lines == 0 then lines = { "" } end
  return { root = root, path = path, language = ft, source = loaded and "buffer" or "disk", lines = lines,
    user_buf = loaded and buf or nil, tick = loaded and vim.api.nvim_buf_get_changedtick(buf) or nil }
end
function M.position_address(address, prefix, cwd)
  local file, line, column = address:sub(#prefix + 1):match("^(.*):(%d+):(%d+)$")
  if not file or file == "" then error("semantic address requires <file>:<line>:<column>") end
  line, column = tonumber(line), tonumber(column)
  if line < 1 or column < 1 then error("line and column must be positive integers") end
  local target = M.target(file, cwd)
  local text = target.lines[line]
  if not text or column > #text + 1 then error("source position is out of range") end
  local byte = text:byte(column)
  if byte and byte >= 128 and byte <= 191 then error("column is inside a UTF-8 character") end
  target.line, target.column = line, column
  return target
end
function M.source_current(target)
  if not target.lines then return true end
  if target.user_buf then
    return vim.api.nvim_buf_is_valid(target.user_buf) and vim.api.nvim_buf_is_loaded(target.user_buf)
      and M.canonical(vim.api.nvim_buf_get_name(target.user_buf)) == target.path
      and vim.api.nvim_buf_get_changedtick(target.user_buf) == target.tick
  end
  local ok, lines = pcall(vim.fn.readfile, target.path)
  if ok and #lines == 0 then lines = { "" } end
  if not ok or not vim.deep_equal(lines, target.lines) then return false end
  local buf = M.buffer(target.path)
  return buf < 0 or not vim.api.nvim_buf_is_loaded(buf)
    or vim.deep_equal(vim.api.nvim_buf_get_lines(buf, 0, -1, false), target.lines)
end
function M.position(target, encoding)
  return { line = target.line - 1,
    character = vim.str_utfindex(target.lines[target.line], encoding or "utf-16", target.column - 1, true) }
end
function M.byte_column(path, position, encoding)
  if type(position) ~= "table" or type(position.line) ~= "number" or type(position.character) ~= "number"
    or position.line < 0 or position.character < 0 or position.line % 1 ~= 0 or position.character % 1 ~= 0 then
    error("LSP returned an invalid position")
  end
  local buf, line = M.buffer(path), nil
  if buf >= 0 and vim.api.nvim_buf_is_loaded(buf) then
    line = vim.api.nvim_buf_get_lines(buf, position.line, position.line + 1, false)[1]
  else
    local file, err = io.open(path, "r")
    if not file then error(err) end
    local index = 0
    for text in file:lines() do
      if index == position.line then line = text; break end
      index = index + 1
    end
    file:close()
  end
  if not line then error("LSP line is unavailable: " .. path) end
  local byte = vim.str_byteindex(line, encoding or "utf-16", position.character, true)
  -- Reject a UTF-16 coordinate splitting a surrogate pair instead of rounding it.
  if vim.str_utfindex(line, encoding or "utf-16", byte, true) ~= position.character then error("LSP position splits a character") end
  return byte + 1
end
function M.range(path, range, encoding, root)
  if type(range) ~= "table" then error("LSP range is unavailable: " .. path) end
  local start, finish = range.start, range["end"]
  local first, last = M.byte_column(path, start, encoding), M.byte_column(path, finish, encoding)
  if finish.line < start.line or (finish.line == start.line and last < first) then error("LSP range is reversed") end
  return string.format("%s:%d:%d-%d:%d", M.label(path, root), start.line + 1, first, finish.line + 1, last)
end
function M.configured_servers(target)
  local configs, languages = {}, {}
  for name in pairs(vim.lsp._enabled_configs or {}) do
    local config = vim.lsp.config[name]
    if config and config.filetypes then
      configs[#configs + 1] = config
      for _, ft in ipairs(config.filetypes) do
        local label = ft:gsub("%.", "_")
        if languages[label] and languages[label] ~= ft then languages[label] = false
        elseif languages[label] == nil then languages[label] = ft end
      end
    end
  end
  if target.language_label then
    target.language = languages[target.language_label]
    if not target.language then error("unknown or ambiguous configured language: " .. target.language_label) end
  end
  local samples = {}
  if target.path then samples[target.language] = target.path else
    local skipped = { [".git"] = true, node_modules = true, [".venv"] = true, __pycache__ = true }
    for relative, kind in vim.fs.dir(target.root, { depth = math.huge, skip = function(dir)
      return not skipped[vim.fs.basename(dir)]
    end }) do
      local basename = vim.fs.basename(relative)
      if kind == "file" and basename ~= ".env" and not basename:match("^%.env%.") then
        local path = target.root .. "/" .. relative
        local ft = M.filetype(path)
        if ft and (not target.language or target.language == ft) and not samples[ft] then samples[ft] = path end
        if target.language and samples[target.language] then break end
      end
    end
  end
  table.sort(configs, function(a, b) return a.name < b.name end)
  local selected = {}
  for _, config in ipairs(configs) do
    for _, ft in ipairs(config.filetypes) do
      if samples[ft] and (not target.language or target.language == ft) then
        selected[#selected + 1] = { config = config, path = samples[ft], filetype = ft }; break
      end
    end
  end
  if #selected == 0 then error("no enabled LSP configuration for scope") end
  return selected
end
function M.request_buffer(path, ft, buffers)
  M.check_file(path)
  local buf = M.buffer(path)
  if buf >= 0 and vim.api.nvim_buf_is_loaded(buf) then
    local leases = vim.b[buf].maxa_neovim_request_leases
    if leases then
      vim.b[buf].maxa_neovim_request_leases = leases + 1
      buffers[#buffers + 1] = buf
    end
    return buf
  end
  if buf < 0 then
    buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(buf, path)
    buffers[#buffers + 1] = buf
    vim.b[buf].maxa_neovim_request_leases = 1
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.fn.readfile(path))
    vim.bo[buf].modified = false
    vim.bo[buf].filetype = ft
  else
    vim.fn.bufload(buf)
    if vim.bo[buf].filetype == "" then vim.bo[buf].filetype = ft end
  end
  return buf
end
function M.validate_search(params, position_query)
  local query, err = require("maxa.interactions.chat.tools.builtin.runtime.search_query").resolve(params, not position_query)
  if not query then return nil, err end
  for key, default in pairs({ case = "sensitive", hidden = false, no_ignore = false }) do
    if params[key] ~= nil and params[key] ~= default then return nil, key .. " is unsupported by LSP search" end
  end
  for _, key in ipairs({ "include", "exclude" }) do
    if params[key] ~= nil and not (type(params[key]) == "table" and vim.islist(params[key]) and #params[key] == 0) then
      return nil, key .. " is unsupported by LSP search"
    end
  end
  if params.output ~= nil and params.output ~= "matches" and params.output ~= "files" then return nil, "output must be matches or files" end
  if params.max_results ~= nil and (type(params.max_results) ~= "number" or params.max_results < 1 or params.max_results % 1 ~= 0) then
    return nil, "max_results must be a positive integer"
  end
  return query
end
-- One deadline covers startup, requests and optional candidate filtering.
function M.run(target, method, response, dispatch, complete, options)
  options = options or {}
  local selected = M.configured_servers(target)
  local session = { clients = {}, buffers = {}, requests = {}, pending = 0, dispatching = true, terminal = false }
  function session:cleanup()
    if self.timer then vim.fn.timer_stop(self.timer); self.timer = nil end
    if self.readiness then vim.fn.timer_stop(self.readiness); self.readiness = nil end
    if self.filter_process then pcall(self.filter_process.kill, self.filter_process, 15); self.filter_process = nil end
    for token in pairs(self.requests) do
      if token.id and not token.complete then pcall(token.client.cancel_request, token.client, token.id) end
    end
    for _, buf in ipairs(self.buffers) do
      if vim.api.nvim_buf_is_valid(buf) then
        local leases = (vim.b[buf].maxa_neovim_request_leases or 1) - 1
        vim.b[buf].maxa_neovim_request_leases = leases > 0 and leases or nil
        if leases == 0 and not vim.bo[buf].modified and not vim.bo[buf].buflisted
          and #vim.fn.win_findbuf(buf) == 0 then pcall(vim.api.nvim_buf_delete, buf, { force = true }) end
      end
    end
    if options.cleanup then options.cleanup() end
  end
  function session:fail(message, deferred)
    if self.terminal then return end
    self.terminal = true; self:cleanup()
    local finish = function() response:error(message) end
    if deferred then vim.schedule(finish) else finish() end
  end
  function session:finish()
    if self.terminal or self.dispatching or self.pending > 0 then return end
    if not M.source_current(target) then return self:fail("stale-source: target changed during LSP query") end
    if options.filter and not self.filtered then
      if self.filtering then return end
      self.filtering = true
      local ok, process = pcall(options.filter, self, function(err)
        if self.terminal then return end
        self.filtering, self.filtered = false, true
        if err then return self:fail(err) end
        self:finish()
      end)
      if not ok then return self:fail(tostring(process)) end
      self.filter_process = process
      if self.terminal and process then pcall(process.kill, process, 15) end
      return
    end
    -- Completion can synchronously start the next wrapped call. Release owned
    -- buffers/requests first so the successor never adopts a disappearing source.
    self.terminal = true; self:cleanup()
    local ok, err = pcall(complete, self)
    if not ok then response:error(tostring(err)) end
  end
  function session:request(owner, operation, args, consume)
    if self.terminal then return end
    local token = { client = owner.client, complete = false }
    self.requests[token] = true; self.pending = self.pending + 1
    local function callback(err, result, ctx)
      if self.terminal or token.complete then return end
      token.complete = true
      local ok, failure = pcall(function()
        if err then error(owner.client.name .. ": " .. tostring(err.message or err)) end
        if not M.source_current(target) then error("stale-source: target changed during LSP query") end
        if result == vim.NIL then result = nil end
        consume(result, ctx)
      end)
      self.pending = self.pending - 1
      if not ok then return self:fail(tostring(failure)) end
      self:finish()
    end
    local ok, sent, id = pcall(owner.client.request, owner.client, operation, args, callback, owner.bufnr)
    if not ok or not sent then return self:fail("LSP request could not be sent: " .. owner.client.name .. ": " .. tostring(sent)) end
    token.id = id
    if self.terminal and not token.complete and id then pcall(owner.client.cancel_request, owner.client, id) end
  end
  bridge.register_handle({ cancel = function(reason) session:fail(reason or "LSP query cancelled", true) end })
  if session.terminal then return end
  session.timer = vim.fn.timer_start(M.TIMEOUT_MS, function() session:fail("LSP query timed out after 10 seconds") end)
  local starting = #selected
  local function start(owner, directory)
    if session.terminal then return end
    local ok, id = pcall(function()
      local config = vim.deepcopy(owner.config)
      config.root_dir = directory
      config.workspace_folders = { { uri = vim.uri_from_fname(directory), name = directory } }
      config.cmd_cwd = config.cmd_cwd or directory
      if options.configure then options.configure(config) end
      return vim.lsp.start(config, { bufnr = owner.bufnr, silent = true, reuse_client = function(client)
        return not client:is_stopped() and client.name == config.name and M.canonical(client.root_dir) == M.canonical(directory)
      end })
    end)
    if not ok or not id then return session:fail("LSP startup failed: " .. owner.config.name .. ": " .. tostring(id)) end
    owner.id = id; session.clients[#session.clients + 1] = owner; starting = starting - 1
  end
  for _, owner in ipairs(selected) do
    local ok, err = pcall(function()
      owner.bufnr = M.request_buffer(owner.path, owner.filetype, session.buffers)
      if target.path and type(owner.config.root_dir) == "function" then
        owner.config.root_dir(owner.bufnr, function(directory)
          if directory then start(owner, directory) else session:fail("LSP configuration declined file: " .. owner.config.name) end
        end)
      else
        start(owner, target.path and (owner.config.root_dir or vim.fs.root(owner.path, owner.config.root_markers or { ".git" }) or vim.fs.dirname(owner.path)) or target.root)
      end
    end)
    if not ok then session:fail(tostring(err)) end
    if session.terminal then return end
  end
  local function ready()
    if session.terminal or starting > 0 then return end
    for _, owner in ipairs(session.clients) do
      owner.client = vim.lsp.get_client_by_id(owner.id)
      if not owner.client or owner.client:is_stopped() then return session:fail("LSP stopped during initialization: " .. owner.config.name) end
      if not owner.client.initialized then return end
    end
    local providers, ids = {}, {}
    for _, owner in ipairs(session.clients) do
      if not ids[owner.id] and (not method or owner.client:supports_method(method, owner.bufnr)) then
        ids[owner.id] = true; providers[#providers + 1] = owner
      end
    end
    if #providers == 0 then return session:fail("No applicable LSP supports " .. tostring(method)) end
    session.clients = providers
    if session.readiness then vim.fn.timer_stop(session.readiness); session.readiness = nil end
    local ok, err = pcall(dispatch, session)
    if not ok then return session:fail(tostring(err)) end
    session.dispatching = false; session:finish()
  end
  session.readiness = vim.fn.timer_start(20, ready, { ["repeat"] = -1 }); ready()
end
return M
