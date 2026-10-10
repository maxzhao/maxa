-- Preserve report identity omitted by vim.diagnostic; bounded process-local observations.
local dir = vim.fs.dirname(debug.getinfo(1, "S").source:sub(2))
local C = dofile(dir .. "/common.lua")
local S = dofile(dir .. "/semantic.lua")
local M = {}
local key = "maxa.neovim.diagnostic-observations"
local state = package.loaded[key]
if not state then state = { reports = {}, order = {}, bytes = 0 }; package.loaded[key] = state end
local PUSH = "textDocument/publishDiagnostics"
local function fingerprint(buf)
  if buf < 0 or not vim.api.nvim_buf_is_loaded(buf) then return nil end
  return vim.fn.sha256(table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n"))
end
local function normalized_uri(uri)
  local path = C.local_uri(uri)
  return path and vim.uri_from_fname(path) or uri
end
local function save(client_id, uri, report)
  uri = normalized_uri(uri)
  local id = tostring(client_id) .. "\0" .. uri
  local old = state.reports[id]
  if old then state.bytes = state.bytes - old.bytes else state.order[#state.order + 1] = id end
  report.bytes = #vim.json.encode(report.items or {})
  report.client_id, report.uri = client_id, uri
  state.reports[id] = report; state.bytes = state.bytes + report.bytes
  while #state.order > 256 or state.bytes > 4000000 do
    local removed = table.remove(state.order, 1)
    state.bytes = state.bytes - state.reports[removed].bytes; state.reports[removed] = nil
  end
end
local function lookup(client_id, uri) return state.reports[tostring(client_id) .. "\0" .. normalized_uri(uri)] end
local function observe(params, ctx)
  if type(params) ~= "table" or not ctx or not ctx.client_id or not C.local_uri(params.uri) then return end
  local buf = C.buffer(C.local_uri(params.uri))
  local version = buf >= 0 and vim.lsp.util.buf_versions[buf] or nil
  local reported_version = type(params.version) == "number" and params.version or nil
  save(ctx.client_id, params.uri, { kind = "push", items = params.diagnostics or {}, version = reported_version,
    fingerprint = reported_version ~= nil and reported_version == version and fingerprint(buf) or nil })
end
local wrappers = setmetatable({}, { __mode = "k" })
-- Wrapper marker lives with state so repeated loadfile calls never stack observers.
state.wrappers = state.wrappers or wrappers
local function wrap(handler)
  if state.wrappers[handler] then return handler end
  local wrapper = function(err, result, ctx, config)
    if not err then observe(result, ctx) end
    return handler(err, result, ctx, config)
  end
  state.wrappers[wrapper] = true
  return wrapper
end
function M.configure(config)
  config.handlers = config.handlers or {}
  config.handlers[PUSH] = wrap(config.handlers[PUSH] or vim.lsp.handlers[PUSH])
end
function M.attach(client)
  client.handlers = client.handlers or {}
  client.handlers[PUSH] = wrap(client.handlers[PUSH] or vim.lsp.handlers[PUSH])
end
local severity = { "error", "warning", "information", "hint" }
local function freshness(report, buf, hash)
  if not report then return "unknown" end
  if report.fingerprint and hash then return report.fingerprint == hash and "current" or "stale" end
  if report.version and buf >= 0 and vim.api.nvim_buf_is_loaded(buf) then
    local version = vim.lsp.util.buf_versions[buf]
    if version and report.version < version then return "stale" end
  end
  return "unknown"
end
local function render(path, owner, report, fallback, root, hash)
  local buf = C.buffer(path)
  local status = freshness(report, buf, hash or fingerprint(buf))
  local items = report and report.items or fallback or {}
  local rows = { string.format("Provider: %s file=%s source=%s freshness=%s count=%d", owner.client.name,
    C.label(path, root), report and report.kind or "cache", status, #items) }
  for _, diagnostic in ipairs(items) do
    local range = diagnostic.range
    local location
    if range then location = C.range(path, range, owner.client.offset_encoding, root) else
      -- vim.diagnostic stores 0-based byte positions, not provider-encoded positions.
      location = C.range(path, { start = { line = diagnostic.lnum, character = diagnostic.col },
        ["end"] = { line = diagnostic.end_lnum or diagnostic.lnum, character = diagnostic.end_col or diagnostic.col } }, "utf-8", root)
    end
    local extra = (diagnostic.code ~= nil and " code=" .. tostring(diagnostic.code) or "")
      .. (diagnostic.source and " source=" .. diagnostic.source or "")
    rows[#rows + 1] = string.format("%s severity=%s message=%s provider=%s%s", location,
      severity[diagnostic.severity or 1] or "information", tostring(diagnostic.message or ""):gsub("[\r\n]", " "), owner.client.name, extra)
  end
  if status == "current" and #items == 0 then rows[#rows + 1] = "no diagnostics in this provider's current report" end
  return table.concat(rows, "\n")
end
local function cached(client, buf)
  local items = {}
  for _, pull in ipairs({ false, true }) do
    local namespace = vim.lsp.diagnostic.get_namespace(client.id, pull)
    vim.list_extend(items, vim.diagnostic.get(buf, { namespace = namespace }))
  end
  return items
end
function M.file(context, response, target, complete)
  local sections, names = {}, {}
  local uri, hash = vim.uri_from_fname(target.path), vim.fn.sha256(table.concat(target.lines, "\n"))
  C.run(target, nil, response, function(session)
    for _, owner in ipairs(session.clients) do
      M.attach(owner.client); names[#names + 1] = owner.client.name
      -- Pull requests flush natively; push/cache observation needs the same sync
      -- boundary even when no protocol request is sent.
      require("vim.lsp._changetracking").flush(owner.client, owner.bufnr)
      if owner.client:supports_method("textDocument/diagnostic", owner.bufnr) then
        local previous = lookup(owner.id, uri)
        local args = { textDocument = { uri = vim.uri_from_bufnr(owner.bufnr) } }
        if previous and previous.kind == "pull" then args.previousResultId = previous.resultId end
        session:request(owner, "textDocument/diagnostic", args, function(result)
          if type(result) ~= "table" or (result.kind ~= "full" and result.kind ~= "unchanged") then error("invalid pull diagnostic report") end
          local report
          if result.kind == "full" then
            report = { kind = "pull", items = result.items or {}, resultId = result.resultId, fingerprint = hash }
            save(owner.id, uri, report)
          elseif previous and previous.kind == "pull" and previous.resultId and args.previousResultId == previous.resultId
            and previous.fingerprint == hash then
            report = { kind = "pull", items = previous.items, resultId = result.resultId or previous.resultId, fingerprint = hash }
            save(owner.id, uri, report)
          else
            -- Unchanged without a matching previous source cannot prove freshness.
            report = { kind = "pull-unchanged", items = previous and previous.items or {},
              fingerprint = previous and previous.fingerprint ~= hash and previous.fingerprint or nil }
          end
          sections[#sections + 1] = render(target.path, owner, report, nil, target.root, hash)
        end)
      else
        sections[#sections + 1] = render(target.path, owner, lookup(owner.id, uri), cached(owner.client, owner.bufnr), target.root, hash)
      end
    end
  end, function()
    complete(S.header(target, "diagnostics", names) .. table.concat(sections, "\n\n"))
  end, { configure = M.configure })
end
function M.project(context)
  local root = C.canonical(context.cwd)
  if not root then error("Chat project root is unavailable") end
  local rows, count, providers = { "Operation: diagnostics\ncoverage=known-cache (not a whole-project check)" }, 0, {}
  for _, client in ipairs(vim.lsp.get_clients()) do
    local client_root = C.canonical(client.root_dir)
    local related = client_root and (C.within(root, client_root) or C.within(client_root, root))
    for _, folder in ipairs(client.workspace_folders or {}) do
      local ok, folder_path = pcall(vim.uri_to_fname, folder.uri)
      local folder_root = ok and C.canonical(folder_path)
      related = related or (folder_root and (C.within(root, folder_root) or C.within(folder_root, root)))
    end
    local entries = {}
    for _, report in pairs(state.reports) do
      if report.client_id == client.id then
        local path = C.local_uri(report.uri)
        if related and path and C.within(path, root) then entries[path] = { report = report } end
      end
    end
    for _, pull in ipairs({ false, true }) do
      local ns = vim.lsp.diagnostic.get_namespace(client.id, pull)
      for _, diagnostic in ipairs(vim.diagnostic.get(nil, { namespace = ns })) do
        local path = C.canonical(vim.api.nvim_buf_get_name(diagnostic.bufnr))
        if related and path and C.within(path, root) and C.local_uri(vim.uri_from_fname(path)) then
          entries[path] = entries[path] or { items = {} }
          if entries[path].items then entries[path].items[#entries[path].items + 1] = diagnostic end
        end
      end
    end
    for _, path in ipairs(vim.tbl_keys(entries)) do
      count = count + 1; providers[client.name] = true
      rows[#rows + 1] = render(path, { client = client }, entries[path].report, entries[path].items, root)
    end
  end
  if count == 0 then rows[#rows + 1] = "0 known entries; coverage unknown; not evidence of a clean project" end
  rows[#rows + 1] = string.format("Observed provider/file entries: %d; providers=%s", count, table.concat(vim.tbl_keys(providers), ", "))
  return table.concat(rows, "\n\n")
end
return M
