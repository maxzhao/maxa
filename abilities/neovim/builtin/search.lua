-- Current-Neovim builtin extension; package-local code is reread per invocation.
local dir = vim.fs.dirname(debug.getinfo(1, "S").source:sub(2))
local common = dofile(dir .. "/common.lua")
local semantic = dofile(dir .. "/semantic.lua")
local Query = require("maxa.interactions.chat.tools.builtin.runtime.search_query")
local Collector = require("maxa.interactions.chat.tools.builtin.runtime.output_collector")
local params_util = require("maxa.mcphub.native_servers.shared.params")
local PREFIX = "@neovim:symbols"
local function scope_target(scope, root)
  if scope == PREFIX then return { root = root } end
  local selector = scope:sub(#PREFIX + 2)
  if selector == "" then error("symbol scope requires a language or file path after ':'") end
  local basename = vim.fs.basename(selector)
  if basename == ".env" or basename:match("^%.env%.") then error("environment files are not code-symbol targets") end
  if basename:match("%.[^.]+$") then
    local target = common.target(selector, root)
    -- Symbol searches retain their existing non-snapshot contract.
    target.lines, target.source, target.user_buf, target.tick = nil, nil, nil, nil
    return target
  end
  return { root = root, language_label = selector }
end
local function run(context, response)
  local params = params_util.normalize(context.params or {})
  local position_query = semantic.match(params.scope)
  local query, err = common.validate_search(params, position_query)
  if not query then return response:error(err) end
  if position_query then return semantic.search(context, response, params, query) end
  local root = common.canonical(context.cwd)
  if not root then return response:error("Chat project root is unavailable") end
  local target = scope_target(params.scope, root)
  local method = target.path and "textDocument/documentSymbol" or "workspace/symbol"
  local collector = Collector.new({ log_prefix = "neovim_symbols" })
  local candidates, candidate_bytes, bounded = {}, 0, false
  local seen, count, truncated = {}, 0, false
  local function collect(owner, symbol)
    local location = symbol.location
    local path = location and common.local_uri(location.uri)
    if not path then return end
    if target.path then
      if path ~= target.path then return end
    elseif not common.within(path, root) or (target.language and common.filetype(path) ~= target.language) then return end
    local name = tostring(symbol.name or ""):gsub("[\r\n]", " ")
    if #candidates >= 10000 or candidate_bytes + #name > 1000000 then bounded = true; return end
    candidates[#candidates + 1] = { owner = owner, symbol = symbol, name = name }
    candidate_bytes = candidate_bytes + #name
  end
  local function record(session, candidate, symbol, resolving)
    if session.terminal then return end
    local owner = candidate.owner
    local location = symbol.location
    local path = location and common.local_uri(location.uri)
    if not path then return end
    if target.path then
      if path ~= target.path then return end
    elseif not common.within(path, root) or (target.language and common.filetype(path) ~= target.language) then return end
    if params.output ~= "files" and not location.range then
      if resolving or not owner.client:supports_method("workspaceSymbol/resolve", owner.bufnr) then
        error("LSP symbol position is unavailable: " .. tostring(symbol.name))
      end
      session:request(owner, "workspaceSymbol/resolve", symbol, function(resolved)
        if type(resolved) ~= "table" then error("LSP symbol resolve returned no symbol") end
        record(session, candidate, resolved, true)
      end)
      return
    end
    local relative = common.label(path, root)
    local key, row
    if params.output == "files" then key, row = path, relative else
      local pos = location.range.start
      local col = common.byte_column(path, pos, owner.client.offset_encoding)
      key = table.concat({ path, pos.line, col, symbol.name or "", symbol.kind or "" }, "\0")
      row = string.format("%s:%d:%d:%s [%s]", relative, pos.line + 1, col,
        tostring(symbol.name or ""):gsub("[\r\n]", " "), vim.lsp.protocol.SymbolKind[symbol.kind] or tostring(symbol.kind))
    end
    if seen[key] then return end
    seen[key] = true
    if params.max_results and count >= params.max_results then truncated = true; return end
    count = count + 1; collector:append_lines("stdout", { row })
  end
  common.run(target, method, response, function(session)
    local function document_symbols(owner, symbols)
      for _, symbol in ipairs(symbols or {}) do
        if session.terminal then return end
        local value = vim.deepcopy(symbol)
        value.location = value.location or { uri = vim.uri_from_bufnr(owner.bufnr), range = value.selectionRange or value.range }
        collect(owner, value)
        if symbol.children then document_symbols(owner, symbol.children) end
      end
    end
    for _, owner in ipairs(session.clients) do
      if target.path then
        session:request(owner, method, { textDocument = { uri = vim.uri_from_bufnr(owner.bufnr) } }, function(symbols)
          document_symbols(owner, symbols)
        end)
      else
        local queries = query.mode == "regex" and { "" } or query.values
        for _, value in ipairs(queries) do
          session:request(owner, method, { query = value }, function(symbols)
            if symbols == nil then return end
            if type(symbols) ~= "table" or not vim.islist(symbols) then error("LSP returned an invalid symbol list") end
            for _, symbol in ipairs(symbols) do collect(owner, symbol) end
          end)
        end
      end
    end
  end, function(session)
    local names = {}
    for _, owner in ipairs(session.clients) do names[#names + 1] = owner.client.name end
    local header = "Scope: " .. (target.path or root) .. "\nSource: LSP " .. method .. " (" .. table.concat(names, ", ") .. ")\n"
    if not target.path and query.mode == "regex" then header = header .. "Coverage: LSP-returned candidates; completeness=unknown\n" end
    local output, failure
    if collector:error() then error(collector:error()) end
    if collector:exceeded() then output, failure = collector:overflow_result(header)
    else output = header .. (count == 0 and "0 symbols" or collector:stdout():gsub("\n$", "")) end
    collector:close()
    if failure then error(failure) end
    if truncated then output = output .. string.format("\n[truncated: max_results=%d]", params.max_results) end
    if bounded then output = output .. "\n[truncated: bounded LSP candidates]" end
    response:text(output):send()
  end, {
    filter = function(session, done)
      local names = {}
      for index, candidate in ipairs(candidates) do names[index] = candidate.name end
      -- Workspace text is already matched by the provider, not a local substring.
      local filter = not target.path and query.mode == "text" and { mode = "none", values = {} } or query
      return Query.filter(filter, names, function(matched, failure)
        if session.terminal then return end
        if failure then return done(failure) end
        local ok, problem = pcall(function()
          for index, candidate in ipairs(candidates) do
            if matched[index] then record(session, candidate, candidate.symbol, false) end
          end
        end)
        done(not ok and tostring(problem) or nil)
      end)
    end,
    cleanup = function() collector:close() end,
  })
end
return {
  match = function(context)
    local scope = context.params and context.params.scope
    return type(scope) == "string" and (scope == PREFIX or scope:sub(1, #PREFIX + 1) == PREFIX .. ":" or semantic.match(scope)) or false
  end,
  run = run,
}
