-- Run: nvim --headless -u NONE -l abilities/neovim/builtin/readonly_test.lua
vim.opt.runtimepath:prepend(vim.fn.getcwd())
vim.opt.runtimepath:append(vim.fn.stdpath("data") .. "/lazy/plenary.nvim")
package.loaded["maxa.config"] = { constants = { USER_ROLE = "user", LLM_ROLE = "assistant" } }
package.loaded["maxa.mcphub.utils.config_manager"] = {
  get_effective_catalog = function() return { servers = {} } end, is_server_disabled = function() return false end,
}
local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")
local path = root .. "/sample:colon.lua"
local original = { "中😀abc", "local f = function() end", "f()" }
vim.fn.writefile(original, path)
local uri = vim.uri_from_fname(path)
local adapter = require("maxa.interactions.chat.tools.builtin.runtime.adapter")
local inventory = require("maxa.interactions.chat.tools.builtin")
local catalog = require("maxa.abilities.catalog")
local abilities = require("maxa.session.abilities")
local ability = assert(catalog.resolve("neovim", root))
local revision = abilities.build_revision({ ability = ability })
local _, loaded = abilities.synthetic_catalog_pair(revision, "load-neovim")
local chat = { messages = { loaded }, opts = { cwd = root } }
vim.list_extend(chat.messages, abilities.build_context_batch(revision, "Loaded test instructions.", nil, "load-neovim"))
local methods, sent, starts, handler = {}, {}, 0, nil
local clients = {}
for id = 1, 2 do
  clients[id] = { id = id, name = "fixture" .. id, initialized = true, root_dir = root, handlers = {}, server_capabilities = {},
    offset_encoding = id == 1 and "utf-16" or "utf-8", is_stopped = function() return false end,
    flags = {}, stop = function() end, _effective_capabilities = { textDocumentSync = { change = 1 } },
    supports_method = function(_, method) return methods[method] == true end,
    cancel_request = function(_, request_id) sent.cancelled = request_id end,
    request = function(self, method, params, callback, buf)
      sent[#sent + 1] = { id = self.id, method = method, params = params, buf = buf }
      handler(self, method, params, callback, buf)
      return true, #sent
    end,
  }
end
vim.lsp._enabled_configs = { fixture1 = {}, fixture2 = {} }
for id = 1, 2 do vim.lsp.config["fixture" .. id] = { filetypes = { "lua" }, cmd = { "fixture" }, root_dir = root } end
vim.lsp.start = function(config, opts)
  starts = starts + 1
  assert(vim.api.nvim_buf_is_loaded(opts.bufnr)); assert(config.root_dir == root)
  return tonumber(config.name:sub(-1))
end
vim.lsp.get_client_by_id = function(id) return clients[id] end
vim.lsp.get_clients = function() return { clients[1], clients[2] } end
local function invoke(tool, params, owner)
  local result
  adapter.invoke(inventory.resolve(tool), { cwd = root, chat = owner or chat, params = params,
    caller = { maxa_ai = { chat = owner or chat } } }, function(value) result = value end)
  assert(vim.wait(2000, function() return result ~= nil end), "query did not complete")
  return result
end
local function text(result)
  assert(result.ok, result.error); return adapter.content_to_result(result.content)
end
local function search(op, options)
  options = options or {}; options.scope = "@neovim:" .. op .. ":sample:colon.lua:1:8"
  return invoke("search", options)
end
local function range(client)
  local col = client.id == 1 and 3 or 7
  return { start = { line = 0, character = col }, ["end"] = { line = 0, character = col + 1 } }
end
methods["textDocument/definition"] = true
handler = function(client, method, params, callback)
  assert(method == "textDocument/definition")
  assert(params.position.line == 0 and params.position.character == (client.id == 1 and 3 or 7), "byte to provider encoding")
  callback(nil, client.id == 1 and { uri = uri, range = range(client) }
    or { { targetUri = uri, targetSelectionRange = range(client), targetRange = range(client) } })
end
local output = text(search("definition"))
assert(output:find("source=disk", 1, true) and output:find("sample:colon.lua:1:8-1:9", 1, true), output)
assert(output:find("providers=fixture1,fixture2", 1, true), output)
assert(vim.fn.bufnr(path) == -1, "hidden buffers must be removed")
local search_params = { scope = "@neovim:definition:sample:colon.lua:1:8" }
assert(text(invoke("run", { title = "definition", scope = "tool", command = "search", args = vim.json.encode(search_params) })) == output)
local native_batch = require("maxa.interactions.chat.tools.builtin.tests.native_batch_fixture")
local search_batch = native_batch.execute(chat, { title = "navigation paths", mode = "sequence", runs = {
  { scope = "tool", command = "search", args = vim.json.encode(search_params) },
  { scope = "tool", command = "search", args = vim.json.encode(search_params) },
} })
assert(search_batch.summary.status == "completed" and search_batch.members[1].text == output and search_batch.members[2].text == output,
  "completion must release hidden buffers before a sequential wrapped call starts")
for _, address in ipairs({ "sample:colon.lua:1:2", "sample:colon.lua:0:1", "sample:colon.lua:9:1", "sample:colon.lua:1:99", "sample:colon.lua", "missing.lua:1:1" }) do
  local count = #sent
  assert(not invoke("search", { scope = "@neovim:definition:" .. address }).ok)
  assert(#sent == count, "invalid position sent a request")
end
assert(invoke("search", { scope = "@neovim:definition:" .. path .. ":1:8" }).ok)
assert(text(search("definition", { text = { "not-found", "1:8" }, max_results = 1 })):find("providers=fixture1,fixture2", 1, true))
assert(text(search("definition", { output = "files" })):match("sample:colon.lua$"))
assert(text(search("definition", { text = "NOT-FOUND" })):find("0 results", 1, true))
assert(text(search("definition", { text = "*" })):find("0 results", 1, true), "star must be literal")
assert(text(search("definition", { regex = "sample:colon\\.lua:1:8" })):find("providers=fixture1,fixture2", 1, true))
assert(not search("definition", { regex = "(" }).ok)
local definition_handler = handler
handler = function(client, _, _, callback)
  local first_range = range(client)
  local second_range = { start = { line = 2, character = 0 }, ["end"] = { line = 2, character = 1 } }
  callback(nil, { { targetUri = uri, targetRange = first_range }, { uri = uri, range = second_range } })
end
assert(text(search("definition", { max_results = 1 })):find("[truncated: max_results=1]", 1, true))
handler = definition_handler
-- Concurrent read-only calls lease the same hidden source until both complete.
local callbacks, concurrent = {}, {}
handler = function(_, _, _, callback) callbacks[#callbacks + 1] = callback end
for index = 1, 2 do
  adapter.invoke(inventory.resolve("search"), { cwd = root, chat = chat, params = search_params },
    function(value) concurrent[index] = value end)
end
assert(#callbacks == 4 and vim.fn.bufnr(path) >= 0)
callbacks[1](nil, {}); callbacks[2](nil, {})
assert(concurrent[1].ok and vim.fn.bufnr(path) >= 0, "first completion deleted another call's request source")
callbacks[3](nil, {}); callbacks[4](nil, {})
assert(concurrent[2].ok and text(concurrent[2]):find("source=disk", 1, true) and vim.fn.bufnr(path) == -1)
handler = definition_handler
assert(not search("definition", { case = "insensitive" }).ok)
-- Unsupported auxiliary providers are skipped; empty is distinct from unsupported.
clients[2].supports_method = function() return false end
handler = function(_, _, _, callback) callback(nil, nil) end
assert(text(search("definition")):find("0 results", 1, true))
methods["textDocument/definition"] = false
assert(not search("definition").ok)
methods["textDocument/definition"] = true
clients[2].supports_method = clients[1].supports_method
handler = function(_, _, _, callback) callback(nil, { uri = "https://invalid", range = {} }) end
assert(not search("definition").ok)
methods["textDocument/references"] = true
handler = function(_, _, params, callback)
  assert(params.context.includeDeclaration == sent.expect_declaration); callback(nil, {})
end
sent.expect_declaration = false; assert(search("references").ok)
sent.expect_declaration = true; assert(search("references-with-declaration").ok)
-- Buffer precedence, stale source, and no source/window mutations.
local buf = vim.api.nvim_create_buf(true, false)
assert(vim.uv.fs_symlink(path, root .. "/alias.lua"))
vim.api.nvim_buf_set_name(buf, root .. "/alias.lua"); vim.bo[buf].filetype = "lua"
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "中😀xyz", original[2], original[3] })
local windows = vim.api.nvim_list_wins()
handler = function(_, _, params, callback, target_buf)
  assert(target_buf == buf and params.position.character ~= nil)
  assert(vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] == "中😀xyz")
  callback(nil, {})
end
assert(text(search("definition")):find("source=buffer", 1, true))
assert(vim.bo[buf].modified and vim.deep_equal(windows, vim.api.nvim_list_wins()))
assert(vim.deep_equal(vim.fn.readfile(path), original))
handler = function(_, _, _, callback)
  vim.api.nvim_buf_set_lines(buf, 1, 2, false, { "changed" }); callback(nil, {})
end
local stale = search("definition")
assert(not stale.ok and stale.error:find("stale-source", 1, true))
-- One-hop relations retain all prepared identities and opaque provider data.
methods["textDocument/prepareCallHierarchy"], methods["callHierarchy/incomingCalls"], methods["callHierarchy/outgoingCalls"] = true, true, true
handler = function(client, method, params, callback)
  local item = { name = "f", uri = uri, range = range(client), selectionRange = range(client), data = { owner = client.id } }
  if method == "textDocument/prepareCallHierarchy" then
    local second = vim.deepcopy(item); second.name = "g"; callback(nil, { item, second })
  else
    assert(params.item.data.owner == client.id)
    callback(nil, { { from = item, to = item, fromRanges = { range(client) } } })
  end
end
local incoming = text(search("incoming-calls"))
assert(incoming:find("callee=g", 1, true) and incoming:find("call-sites=sample:colon.lua:1:8-1:9", 1, true))
assert(text(search("outgoing-calls", { output = "files" })):match("sample:colon.lua$"))
methods["callHierarchy/outgoingCalls"] = false
assert(not search("outgoing-calls").ok)
methods["callHierarchy/outgoingCalls"] = true
-- Actual adapter and wrappers must preserve 20k semantic read chunks and frozen content.
methods["textDocument/hover"] = true
local hover = "@neovim:hover:sample:colon.lua:1:8"
handler = function(client, _, _, callback)
  callback(nil, { contents = { kind = client.id == 1 and "markdown" or "plaintext", value = string.rep("é", 11000) .. " provider" .. client.id } })
end
local first = text(invoke("read", { path = hover, result_policy = "keep" }))
assert(#first <= 20000 and #first > 10500 and first:match("^next_cursor:"), "adapter replaced read chunk")
local cursor = first:match("^next_cursor: ([^\n]+)")
assert(cursor ~= "none")
local requests_before = #sent
local continuation = text(invoke("read", { path = hover, result_policy = "keep", cursor = cursor }))
assert(#sent == requests_before and continuation:match("^next_cursor:"), "continuation requeried LSP")
assert(not invoke("read", { path = hover, result_policy = "persist", cursor = cursor }).ok)
assert(not invoke("read", { path = "@neovim:diagnostics", result_policy = "keep", cursor = cursor }).ok)
assert(not invoke("read", { path = hover, result_policy = "keep", cursor = cursor }, { messages = chat.messages }).ok)
assert(not invoke("read", { path = hover, result_policy = "temporary", end_line = 1 }).ok)
assert(not invoke("read", { path = hover, force = true }).ok)
local bounded = text(invoke("read", { path = hover, result_policy = "keep", start_line = 1, end_line = 1 }))
assert(bounded == "next_cursor: none\n---\nOperation: hover\n")
local read_args = vim.json.encode({ path = hover, result_policy = "keep" })
local wrapped = text(invoke("run", { title = "hover", scope = "tool", command = "read", args = read_args }))
assert(wrapped == first, "direct/wrapped semantic read differs")
local batch = native_batch.execute(chat, { title = "readonly paths", runs = {
  { scope = "tool", command = "read", args = read_args },
} })
assert(batch.summary.status == "completed" and batch.members[1].text == first, "multicall changed semantic read protocol")
local joined, next_token = first:gsub("^next_cursor: [^\n]+\n%-%-%-\n", ""), cursor
for _ = 1, 8 do
  local chunk = text(invoke("read", { path = hover, result_policy = "keep", cursor = next_token }))
  next_token = chunk:match("^next_cursor: ([^\n]+)")
  joined = joined .. chunk:gsub("^next_cursor: [^\n]+\n%-%-%-\n", "")
  if next_token == "none" then break end
end
assert(next_token == "none" and joined:find("provider1", 1, true) and joined:find("provider2", 1, true))
assert(select(2, joined:gsub("é", "")) == 22000, "semantic cursor lost UTF-8 content")
local snapshots = package.loaded["maxa.neovim.read-snapshots"][chat]
for _, report in pairs(snapshots.reports) do report.created = vim.uv.now() - 300001 end
assert(not invoke("read", { path = hover, result_policy = "keep", cursor = cursor }).ok)
-- Full/unchanged pull and observed push/cache freshness.
methods["textDocument/diagnostic"] = true
handler = function(_, _, _, callback) callback(nil, { kind = "full", resultId = "r1", items = {} }) end
local diagnostic_path = "@neovim:diagnostics:sample:colon.lua"
local clean = text(invoke("read", { path = diagnostic_path }))
assert(clean:find("freshness=current count=0", 1, true))
handler = function(_, _, params, callback)
  assert(params.previousResultId == "r1"); callback(nil, { kind = "unchanged", resultId = "r1" })
end
assert(text(invoke("read", { path = diagnostic_path })):find("freshness=current", 1, true))
vim.api.nvim_buf_set_lines(buf, 1, 2, false, { "newer" })
assert(text(invoke("read", { path = diagnostic_path })):find("freshness=stale", 1, true))
methods["textDocument/diagnostic"] = false
-- Clear pull observations to test empty push-only reports.
package.loaded["maxa.neovim.diagnostic-observations"].reports = {}
package.loaded["maxa.neovim.diagnostic-observations"].order = {}
package.loaded["maxa.neovim.diagnostic-observations"].bytes = 0
assert(text(invoke("read", { path = diagnostic_path })):find("freshness=unknown count=0", 1, true))
for id = 1, 2 do
  clients[id].handlers["textDocument/publishDiagnostics"](nil, { uri = uri, version = vim.lsp.util.buf_versions[buf], diagnostics = {} }, { client_id = id })
end
assert(text(invoke("read", { path = diagnostic_path })):find("freshness=current count=0", 1, true))
methods["textDocument/diagnostic"] = true
handler = function(_, _, params, callback)
  assert(params.previousResultId == nil); callback(nil, { kind = "unchanged", resultId = "not-a-pull-predecessor" })
end
assert(text(invoke("read", { path = diagnostic_path })):find("freshness=unknown", 1, true),
  "a matching push source cannot authorize unchanged pull freshness")
methods["textDocument/diagnostic"] = false
vim.api.nvim_buf_set_lines(buf, 1, 2, false, { "newest" })
assert(text(invoke("read", { path = diagnostic_path })):find("freshness=stale", 1, true))
for id = 1, 2 do
  clients[id].handlers["textDocument/publishDiagnostics"](nil, { uri = uri, version = vim.NIL, diagnostics = {} }, { client_id = id })
end
assert(text(invoke("read", { path = diagnostic_path })):find("freshness=unknown", 1, true))
local old_starts = starts
local project = text(invoke("read", { path = "@neovim:diagnostics" }))
assert(project:find("coverage=known-cache", 1, true) and starts == old_starts)
-- Missing previous source identity does not establish current for unchanged pull.
methods["textDocument/diagnostic"] = true
handler = function(_, _, _, callback) callback(nil, { kind = "unchanged", resultId = "missing" }) end
assert(text(invoke("read", { path = diagnostic_path })):find("freshness=unknown", 1, true))
handler = function(client, _, _, callback)
  callback(nil, { kind = "full", resultId = "errors", items = {
    { range = range(client), severity = 2, message = "warning message", code = "W1", source = "fixture-source" },
    { range = range(client), severity = 4, message = "hint message" },
  } })
end
local diagnostic_rows = text(invoke("read", { path = diagnostic_path }))
assert(diagnostic_rows:find("severity=warning message=warning message", 1, true))
assert(diagnostic_rows:find("code=W1 source=fixture-source", 1, true) and diagnostic_rows:find("severity=hint", 1, true))
-- Known-cache must exclude non-LSP namespaces and unrelated workspace reports.
local unrelated_ns = vim.api.nvim_create_namespace("non-LSP-fixture")
vim.diagnostic.set(unrelated_ns, buf, { { lnum = 0, col = 0, message = "NON_LSP_MUST_NOT_APPEAR" } })
assert(not text(invoke("read", { path = "@neovim:diagnostics" })):find("NON_LSP_MUST_NOT_APPEAR", 1, true))
local unrelated_root = vim.fn.tempname(); vim.fn.mkdir(unrelated_root, "p")
clients[1].root_dir, clients[2].root_dir = unrelated_root, unrelated_root
assert(text(invoke("read", { path = "@neovim:diagnostics" })):find("0 known entries", 1, true))
clients[1].root_dir, clients[2].root_dir = root, root
vim.fn.delete(unrelated_root, "d")
-- Cooperative cancellation cancels follow-up requests and rejects late completion.
local bridge = require("maxa.interactions.chat.tools.builtin.runtime.async_cancel_bridge")
local callback, result, completed = nil, nil, 0
handler = function(client, method, _, cb)
  if method == "textDocument/prepareCallHierarchy" then
    cb(nil, { { name = "f", uri = uri, range = range(client), data = client.id } })
  else callback = cb end
end
bridge.with_context({ async_id = "semantic-cancel" }, function()
  adapter.invoke(inventory.resolve("search"), { cwd = root, chat = chat,
    params = { scope = "@neovim:incoming-calls:sample:colon.lua:1:8" } }, function(value) completed = completed + 1; result = value end)
end)
assert(bridge.cancel("semantic-cancel").cancelled == 1)
assert(vim.wait(1000, function() return result ~= nil end) and not result.ok and sent.cancelled)
callback(nil, {}); assert(completed == 1)
bridge.clear("semantic-cancel")
assert(vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].modified)
vim.api.nvim_buf_delete(buf, { force = true })
vim.fn.delete(root, "rf")
print("NEOVIM_READONLY_TEST_OK")
