-- Frozen semantic reports are bounded, Chat-local and never persisted to disk.
local dir = vim.fs.dirname(debug.getinfo(1, "S").source:sub(2))
local C = dofile(dir .. "/common.lua")
local S = dofile(dir .. "/semantic.lua")
local D = dofile(dir .. "/diagnostics.lua")
local reader = require("maxa.interactions.chat.tools.builtin.tools.builtin_read")
local params_util = require("maxa.mcphub.native_servers.shared.params")
local key = "maxa.neovim.read-snapshots"
local chats = package.loaded[key]
if not chats then chats = setmetatable({}, { __mode = "k" }); package.loaded[key] = chats end
local MAX_BYTES, MAX_REPORTS, MAX_AGE = 4000000, 8, 300000
local function match(context)
  local path = context.params and context.params.path
  return type(path) == "string" and (path == "@neovim:diagnostics" or path:sub(1, 20) == "@neovim:diagnostics:"
    or path:sub(1, 14) == "@neovim:hover:") or false
end
local function run(context, response)
  local params = params_util.normalize(context.params or {})
  local policy, err = reader.validate_request(params)
  if not policy then return response:error(err) end
  local chat = context.chat
  if not chat then return response:error("Exact Chat context is required for semantic read snapshots") end
  local state = chats[chat]
  if not state then state = { reports = {}, order = {}, bytes = 0 }; chats[chat] = state end
  local now = vim.uv.now()
  for index = #state.order, 1, -1 do
    local hash = state.order[index]
    local report = state.reports[hash]
    if now - report.created > MAX_AGE then
      state.bytes = state.bytes - #report.content; state.reports[hash] = nil; table.remove(state.order, index)
    end
  end
  if params.cursor then
    local hash = params.cursor:match("^[0-9a-f]+%.[0-9a-f]+%.([0-9a-f]+)$")
    local report = hash and state.reports[hash]
    if not report or report.path ~= params.path or report.policy ~= policy or report.cwd ~= context.cwd then
      return response:error("Semantic cursor snapshot expired, missing, or address/result_policy mismatch; start a new read")
    end
    return reader.respond_content(context, response, params, params.path, report.content)
  end
  local function complete(content)
    if #content > MAX_BYTES then return response:error("Semantic report exceeds the bounded snapshot limit") end
    local hash = reader.content_hash(params, params.path, content)
    if not state.reports[hash] then
      state.order[#state.order + 1] = hash; state.bytes = state.bytes + #content
    end
    state.reports[hash] = { path = params.path, policy = policy, cwd = context.cwd, content = content, created = vim.uv.now() }
    while #state.order > MAX_REPORTS or state.bytes > MAX_BYTES do
      local first = table.remove(state.order, 1)
      state.bytes = state.bytes - #state.reports[first].content; state.reports[first] = nil
    end
    return reader.respond_content(context, response, params, params.path, content)
  end
  if params.path == "@neovim:diagnostics" then return complete(D.project(context)) end
  if params.path:sub(1, 14) == "@neovim:hover:" then
    local target = C.position_address(params.path, "@neovim:hover:", context.cwd)
    return S.hover(context, response, target, complete)
  end
  local target = C.target(params.path:sub(#"@neovim:diagnostics:" + 1), context.cwd)
  return D.file(context, response, target, complete)
end
return { match = match, run = run }
