local dir = vim.fs.dirname(debug.getinfo(1, "S").source:sub(2))
local C = dofile(dir .. "/common.lua")
local Query = require("maxa.interactions.chat.tools.builtin.runtime.search_query")
local M = {}
M.methods = {
  definition = "textDocument/definition", declaration = "textDocument/declaration",
  implementation = "textDocument/implementation", ["type-definition"] = "textDocument/typeDefinition",
  references = "textDocument/references", ["references-with-declaration"] = "textDocument/references",
  ["incoming-calls"] = "textDocument/prepareCallHierarchy", ["outgoing-calls"] = "textDocument/prepareCallHierarchy",
}
function M.operation(address) return type(address) == "string" and address:match("^@neovim:([^:]+):") end
function M.match(address) return M.methods[M.operation(address)] ~= nil end
function M.header(target, operation, providers)
  return string.format("Operation: %s\nSource: %s:%d:%d source=%s\nProviders: %s\n", operation,
    C.label(target.path, target.root), target.line or 1, target.column or 1, target.source, table.concat(providers, ", "))
end
function M.location(uri, range, owner, root)
  local path = C.local_uri(uri)
  if not path then error("unsupported URI or unavailable LSP destination: " .. tostring(uri)) end
  return C.range(path, range, owner.client.offset_encoding, root), C.label(path, root)
end
local function list(value)
  if value == nil or value == vim.NIL then return {} end
  if type(value) ~= "table" or not vim.islist(value) then error("LSP returned an invalid result list") end
  return value
end
function M.search(context, response, params, query)
  local operation = M.operation(params.scope)
  local target = C.position_address(params.scope, "@neovim:" .. operation .. ":", context.cwd)
  local method = M.methods[operation]
  local incoming, outgoing = operation == "incoming-calls", operation == "outgoing-calls"
  local direction = incoming and "callHierarchy/incomingCalls" or "callHierarchy/outgoingCalls"
  local records, order, names, bytes, bounded = {}, {}, {}, 0, false
  local function record(row, file, provider)
    local entry = records[row]
    if not entry then
      if #order >= 10000 or bytes + #row > 1000000 then bounded = true; return end
      entry = { row = row, file = file, providers = {} }; records[row] = entry; order[#order + 1] = entry; bytes = bytes + #row
    end
    entry.providers[provider] = true
  end
  local function identity(item, owner)
    if type(item) ~= "table" then error("invalid call hierarchy item") end
    local range = item.selectionRange or item.range
    local location = M.location(item.uri, range, owner, target.root)
    return tostring(item.name or ""):gsub("[\r\n]", " ") .. " [" .. location .. "]"
  end
  C.run(target, method, response, function(session)
    local capable = 0
    for _, owner in ipairs(session.clients) do
      if not (incoming or outgoing) or owner.client:supports_method(direction, owner.bufnr) then
        capable = capable + 1; names[#names + 1] = owner.client.name
        local args = { textDocument = { uri = vim.uri_from_bufnr(owner.bufnr) }, position = C.position(target, owner.client.offset_encoding) }
        if method == "textDocument/references" then args.context = { includeDeclaration = operation == "references-with-declaration" } end
        session:request(owner, method, args, function(result)
          if incoming or outgoing then
            for _, item in ipairs(list(result)) do
              local prepared = identity(item, owner)
              session:request(owner, direction, { item = item }, function(relations)
                for _, relation in ipairs(list(relations)) do
                  local other = incoming and relation.from or relation.to
                  local caller, callee = incoming and identity(other, owner) or prepared, incoming and prepared or identity(other, owner)
                  local caller_uri = incoming and other.uri or item.uri
                  local _, file = M.location(other.uri, other.selectionRange or other.range, owner, target.root)
                  local sites, seen_sites = {}, {}
                  for _, range in ipairs(list(relation.fromRanges)) do
                    local site = M.location(caller_uri, range, owner, target.root)
                    if not seen_sites[site] then sites[#sites + 1] = site; seen_sites[site] = true end
                  end
                  table.sort(sites)
                  record("caller=" .. caller .. " -> callee=" .. callee .. " call-sites=" .. (#sites == 0 and "none" or table.concat(sites, ", ")),
                    file, owner.client.name)
                end
              end)
            end
          else
            if result and (result.uri or result.targetUri) then result = { result } end
            for _, location in ipairs(list(result)) do
              local row, file = M.location(location.targetUri or location.uri,
                location.targetSelectionRange or location.targetRange or location.range, owner, target.root)
              record(row, file, owner.client.name)
            end
          end
        end)
      end
    end
    if capable == 0 then error("No applicable LSP supports " .. direction) end
  end, function()
    local rows, files, count, truncated = {}, {}, 0, bounded
    for _, entry in ipairs(order) do
      if entry.matched and (params.output ~= "files" or not files[entry.file]) then
        files[entry.file] = true
        if params.max_results and count >= params.max_results then truncated = true else
          count = count + 1; rows[#rows + 1] = params.output == "files" and entry.file or entry.rendered
        end
      end
    end
    if count == 0 then rows[1] = "0 results" end
    if truncated then rows[#rows + 1] = params.max_results and string.format("[truncated: max_results=%d]", params.max_results)
      or "[truncated: bounded semantic output]" end
    response:text(M.header(target, operation, names) .. table.concat(rows, "\n")):send()
  end, {
    filter = function(session, done)
      table.sort(order, function(a, b) return a.row < b.row end)
      local rows = {}
      for index, entry in ipairs(order) do
        local providers = vim.tbl_keys(entry.providers); table.sort(providers)
        entry.rendered = entry.row .. " [providers=" .. table.concat(providers, ",") .. "]"
        rows[index] = entry.rendered
      end
      return Query.filter(query, rows, function(matched, failure)
        if session.terminal then return end
        if failure then return done(failure) end
        for index, entry in ipairs(order) do entry.matched = matched[index] end
        done()
      end)
    end,
  })
end
function M.hover(context, response, target, complete)
  local sections, names = {}, {}
  C.run(target, "textDocument/hover", response, function(session)
    for _, owner in ipairs(session.clients) do
      names[#names + 1] = owner.client.name
      session:request(owner, "textDocument/hover", {
        textDocument = { uri = vim.uri_from_bufnr(owner.bufnr) }, position = C.position(target, owner.client.offset_encoding),
      }, function(result)
        local contents = result and result.contents
        local lines = contents and vim.lsp.util.convert_input_to_markdown_lines(contents) or {}
        local kind = type(contents) == "table" and contents.kind or "markdown"
        sections[#sections + 1] = "Provider: " .. owner.client.name .. " content=" .. tostring(kind) .. "\n"
          .. (#lines == 0 and "no hover information" or table.concat(lines, "\n"))
      end)
    end
  end, function() complete(M.header(target, "hover", names) .. table.concat(sections, "\n\n")) end)
end
return M
