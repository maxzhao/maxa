-- Run: nvim --headless -u NONE -l abilities/neovim/builtin/search_test.lua
vim.opt.runtimepath:prepend(vim.fn.getcwd())
local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")
vim.fn.writefile({ "中abc", "local symbol = true" }, root .. "/sample.lua")
local uri = vim.uri_from_fname(root .. "/sample.lua")
local source = { name = "symbol", kind = 12, location = { uri = uri, range = { start = { line = 0, character = 1 } } } }
local adapter = require("maxa.interactions.chat.tools.builtin.runtime.adapter")
local bridge = require("maxa.interactions.chat.tools.builtin.runtime.async_cancel_bridge")
local extension = dofile("abilities/neovim/builtin/search.lua")
local client = {
  name = "lua-fixture", root_dir = root, config = { filetypes = { "lua" } }, offset_encoding = "utf-16",
  server_capabilities = { workspaceSymbolProvider = true }, attached_buffers = {}, initialized = true,
  is_stopped = function() return false end,
  supports_method = function() return true end,
}
local requests, cancelled = {}, {}
local starts = 0
client.cancel_request = function(_, id) cancelled[#cancelled + 1] = id end
local original_start, original_get = vim.lsp.start, vim.lsp.get_client_by_id
vim.lsp._enabled_configs = { ["lua-fixture"] = {} }
vim.lsp.config["lua-fixture"] = { filetypes = { "lua" }, cmd = { "fixture" } }
vim.lsp.start = function(config, opts)
  starts = starts + 1
  assert(config.root_dir == root, "workspace must be supplied without opening a window")
  assert(vim.api.nvim_buf_is_loaded(opts.bufnr))
  return 99
end
vim.lsp.get_client_by_id = function(id) assert(id == 99); return client end
local function run(params)
  local result
  local response = adapter.Result.new(function(value) result = value end)
  params = params or { text = "symbol" }
  params.scope = params.scope or "@neovim:symbols:lua"
  extension.run({ params = params, cwd = root }, response)
  return function()
    assert(vim.wait(2000, function() return result ~= nil end), "query did not complete")
    return result
  end
end
assert(extension.match({ params = { scope = "@neovim:symbols" } }))
assert(extension.match({ params = { scope = "@neovim:symbols:lua" } }))
assert(not extension.match({ params = { scope = "@neovim:symbols/lua" } }))
assert(not extension.match({ params = { scope = "@neovim" } }))
client.request = function(_, method, _, callback)
  requests[#requests + 1] = method
  callback(nil, { source, source }) -- synchronous response and duplicates
  return true, #requests
end
local result = run({ text = { "one", "two" }, max_results = 1 })()
assert(result.ok, result.error)
local text = adapter.content_to_result(result.content)
assert(text:find("sample.lua:1:4:symbol", 1, true), text)
assert(select(2, text:gsub("sample.lua:1:4", "")) == 1, "deduplicate before limiting")
assert(#requests == 2, "synchronous callbacks must not finish before all queries are dispatched")
assert(not run({ text = "x", literal = true })().ok)
local native_request = client.request
client.request = function(_, method, params, callback)
  assert(method == "workspace/symbol" and params.query == "", "regex must request empty-query candidates")
  callback(nil, {
    { name = "unmatched", location = { uri = uri } }, -- no range; must not resolve a filtered-out symbol
    source, source,
  })
  return true, 7
end
local regex_result = run({ regex = "^sym.*$", max_results = 1 })()
assert(regex_result.ok, regex_result.error)
local regex_text = adapter.content_to_result(regex_result.content)
assert(regex_text:find("sample.lua:1:4:symbol", 1, true) and regex_text:find("completeness=unknown", 1, true))
assert(not regex_text:find("unmatched", 1, true))
assert(not run({ regex = "(" })().ok, "invalid regex must fail")
client.request = native_request
assert(starts > 0, "extension must start/reuse LSP internally")
assert(vim.fn.bufnr(root .. "/sample.lua") == -1, "created hidden request buffer must be removed")
assert(run({scope="@neovim:symbols", text="symbol"})().ok)

client.request = function(_, method, _, callback)
  assert(method == "textDocument/documentSymbol")
  callback(nil, {{name="container", kind=5, range=source.location.range, children={
    {name="symbol",kind=12,selectionRange=source.location.range,range=source.location.range},
  }}})
  return true, 8
end
for _,scope in ipairs({"@neovim:symbols:sample.lua", "@neovim:symbols:./sample.lua", "@neovim:symbols:"..root.."/sample.lua"}) do
  local result=run({scope=scope,text="symbol"})()
  assert(result.ok, result.error)
  assert(adapter.content_to_result(result.content):find("sample.lua:1:4:symbol",1,true))
end
local file_regex = run({scope="@neovim:symbols:sample.lua",regex="^symbol$"})()
assert(file_regex.ok, file_regex.error)
assert(adapter.content_to_result(file_regex.content):find("sample.lua:1:4:symbol",1,true))

-- Auxiliary LSPs without symbol capability must not block a capable provider.
local auxiliary = {
  name = "aux-fixture", initialized = true,
  is_stopped = function() return false end,
  supports_method = function() return false end,
  request = function() error("unsupported auxiliary provider must not receive a request") end,
}
vim.lsp._enabled_configs["aux-fixture"] = {}
vim.lsp.config["aux-fixture"] = {filetypes={"lua"},cmd={"fixture"}}
local fixture_start, fixture_get = vim.lsp.start, vim.lsp.get_client_by_id
vim.lsp.start = function(config, opts)
  if config.name == "aux-fixture" then return 100 end
  return fixture_start(config, opts)
end
vim.lsp.get_client_by_id = function(id)
  return id == 100 and auxiliary or fixture_get(id)
end
local mixed = run({scope="@neovim:symbols:sample.lua",text="symbol"})()
assert(mixed.ok, mixed.error)
local mixed_text = adapter.content_to_result(mixed.content)
assert(mixed_text:find("symbol",1,true) and not mixed_text:find("aux-fixture",1,true))
local document_request = client.request
client.request = function(_, method, _, callback)
  assert(method == "workspace/symbol")
  callback(nil, {source})
  return true, 9
end
assert(run()().ok, "unsupported auxiliary must not block workspace symbols either")
client.supports_method = function() return false end
local unsupported = run()()
assert(not unsupported.ok and unsupported.error:find("No applicable LSP supports workspace/symbol",1,true))
client.request = document_request
local unsupported_file = run({scope="@neovim:symbols:sample.lua",text="symbol"})()
assert(not unsupported_file.ok and unsupported_file.error:find("No applicable LSP supports textDocument/documentSymbol",1,true))
client.supports_method = function() return true end
vim.lsp._enabled_configs["aux-fixture"] = nil
vim.lsp.start, vim.lsp.get_client_by_id = fixture_start, fixture_get

vim.filetype.add({extension={dotted="foo.bar_baz"}})
vim.fn.writefile({"local x=1"},root.."/example.dotted")
vim.lsp._enabled_configs["dotted-fixture"]={}
vim.lsp.config["dotted-fixture"]={filetypes={"foo.bar_baz"},cmd={"fixture"}}
client.request=function(_,method,_,callback) assert(method=="workspace/symbol"); callback(nil,{}); return true,9 end
assert(run({scope="@neovim:symbols:foo_bar_baz",text="symbol"})().ok)
vim.lsp._enabled_configs["dotted-fixture"]=nil

client.request = function(_, method, _, callback)
  if method == "workspace/symbol" then callback(nil, { { name = "symbol", kind = 12, location = { uri = uri }, data = "keep" } })
  else callback(nil, source) end
  return true, 10
end
assert(run()().ok, "URI-only symbols must resolve on their source client")

-- Dynamic document selectors must use a project Lua buffer, not another filetype.
local markdown_buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_name(markdown_buf, root .. "/notes.md")
vim.fn.writefile({ "notes" }, root .. "/notes.md")
vim.bo[markdown_buf].filetype = "markdown"
local lua_buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_name(lua_buf, root .. "/sample.lua")
vim.api.nvim_buf_set_lines(lua_buf, 0, -1, false, { "中abc", "local symbol = true" })
vim.bo[lua_buf].filetype = "lua"
client.attached_buffers = { [markdown_buf] = true, [lua_buf] = true }
client.config.filetypes = { "lua", "markdown" }
client.server_capabilities = {}
client.supports_method = function(_, _, bufnr) return bufnr == lua_buf end
local normal_request = client.request
client.request = function(self, method, params, callback, bufnr)
  assert(bufnr == lua_buf, "dynamic query/resolve must use the project Lua buffer")
  return normal_request(self, method, params, callback)
end
assert(run()().ok)
client.request = normal_request
client.attached_buffers = {}
client.config.filetypes = { "lua" }
client.server_capabilities = { workspaceSymbolProvider = true }
vim.api.nvim_buf_delete(markdown_buf, { force = true })
vim.api.nvim_buf_delete(lua_buf, { force = true })
client.supports_method = function() return false end
assert(not run()().ok, "unsupported workspace symbols must fail explicitly")
client.supports_method = function(_, method) return method ~= "workspaceSymbol/resolve" end
assert(not run()().ok, "unresolved positions must not become fake 1:1 results")
assert(run({ text = "symbol", output = "files" })().ok, "file output does not require range resolution")

local outside = vim.fn.tempname() .. ".lua"
vim.fn.writefile({ "outside" }, outside)
client.request = function(_, _, _, callback)
  callback(nil, { { name = "outside", kind = 12, location = { uri = vim.uri_from_fname(outside), range = source.location.range } } })
  return true, 11
end
assert(adapter.content_to_result(run()().content):find("0 symbols", 1, true))

-- Pending candidate processes share the LSP cancellation/deadline lifecycle.
local Query = require("maxa.interactions.chat.tools.builtin.runtime.search_query")
local original_filter, original_timer = Query.filter, vim.fn.timer_start
local filter_done, killed, deadline
client.request = function(_, _, _, handler) handler(nil, {source}); return true, 13 end
Query.filter = function(_, _, done)
  filter_done = done
  return {kill=function() killed = true end}
end
vim.fn.timer_start = function(ms, cb, opts)
  if ms == 10000 then deadline = cb end
  if opts then return original_timer(ms, cb, opts) end
  return original_timer(ms, cb)
end
for _, reason in ipairs({"cancel", "timeout"}) do
  local pending_result
  killed = false
  bridge.with_context({async_id="filter-"..reason}, function()
    extension.run({cwd=root,params={scope="@neovim:symbols:lua",regex="symbol"}}, adapter.Result.new(function(value) pending_result=value end))
  end)
  assert(not pending_result)
  if reason == "cancel" then bridge.cancel("filter-"..reason) else deadline() end
  assert(vim.wait(1000,function() return pending_result~=nil end))
  assert(not pending_result.ok and killed, "filter must be killed on "..reason)
  filter_done({[1]=true})
  assert(not pending_result.ok, "late filter success must not replace failure")
  bridge.clear("filter-"..reason)
end
Query.filter, vim.fn.timer_start = original_filter, original_timer

local callback
client.request = function(_, _, _, handler) callback = handler; return true, 12 end
local cancelled_result
bridge.with_context({ async_id = "lsp-cancel" }, function()
  extension.run({ cwd = root, params = { scope = "@neovim:symbols:lua", text = "x" } }, adapter.Result.new(function(value) cancelled_result = value end))
end)
assert(bridge.cancel("lsp-cancel").cancelled == 1)
assert(not cancelled_result, "cancel completion must be deferred so outer registry can latch cancelled")
assert(cancelled[1] == 12)
assert(vim.wait(1000, function() return cancelled_result ~= nil end))
assert(not cancelled_result.ok)
callback(nil, { source })
assert(not cancelled_result.ok, "late success must not replace cancelled error")
bridge.clear("lsp-cancel")
vim.lsp.start, vim.lsp.get_client_by_id = original_start, original_get
vim.fn.delete(root, "rf")
vim.fn.delete(outside)
print("NEOVIM_SYMBOL_SEARCH_TEST_OK")
