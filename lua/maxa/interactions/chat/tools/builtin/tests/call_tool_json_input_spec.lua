-- filepath: lua/maxa/interactions/chat/tools/builtin/tests/call_tool_json_input_spec.lua
package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path

_G.vim = _G.vim or {}
vim.fn = vim.fn or {}
vim.fn.stdpath = function(kind)
  assert(kind == "config")
  return vim.loop and vim.loop.cwd() or assert(io.popen("pwd")):read("*l")
end
vim.trim = vim.trim or function(s)
  return tostring(s):match("^%s*(.-)%s*$")
end
vim.split = vim.split
  or function(s, sep, opts)
    sep = sep or "\n"
    local plain = opts and opts.plain
    local out = {}
    local start = 1
    while true do
      local i, j = string.find(s, sep, start, plain)
      if not i then
        table.insert(out, string.sub(s, start))
        break
      end
      table.insert(out, string.sub(s, start, i - 1))
      start = j + 1
    end
    return out
  end
vim.inspect = vim.inspect or tostring
vim.json = vim.json or require("vim.json")
vim.uv = vim.uv or vim.loop
vim.tbl_isempty = vim.tbl_isempty or function(tbl)
  return next(tbl) == nil
end
vim.list_slice = vim.list_slice
  or function(list, start_idx, end_idx)
    local out = {}
    for i = start_idx or 1, end_idx or #list do
      table.insert(out, list[i])
    end
    return out
  end

local function preload(name, value)
  package.loaded[name] = value
end

local Path = {}
Path.__index = Path
function Path:new(...)
  local parts = { ... }
  local path = table.concat(parts, "/")
  path = path:gsub("//+", "/")
  return setmetatable({ path = path }, self)
end
function Path:is_absolute()
  return self.path:sub(1, 1) == "/"
end
function Path:absolute()
  if self:is_absolute() then
    return self.path
  end
  return (vim.loop and vim.loop.cwd() or assert(io.popen("pwd")):read("*l")) .. "/" .. self.path
end
function Path:exists()
  local f = io.open(self:absolute(), "rb")
  if f then
    f:close()
    return true
  end
  return false
end
function Path:is_dir()
  local p = io.popen('[ -d "' .. self:absolute() .. '" ] && echo yes || echo no')
  local result = p:read("*l")
  p:close()
  return result == "yes"
end
function Path:read()
  local f = assert(io.open(self:absolute(), "rb"))
  local content = f:read("*a")
  f:close()
  return content
end
function Path:write(content)
  local f = assert(io.open(self:absolute(), "wb"))
  f:write(content)
  f:close()
end
function Path:mkdir()
  os.execute('mkdir -p "' .. self:absolute() .. '"')
end
preload("plenary.path", Path)

preload("maxa.interactions.chat.tools.builtin.runtime.utils", {
  MAX_OUTPUT_CHARS = 100000,
  MAX_ERROR_OUTPUT_CHARS = 4096,
  MAX_ERROR_PREVIEW_CHARS = 2048,
  validate_required_string = function(value, field)
    if type(value) ~= "string" or value == "" then
      return false, field .. " is required"
    end
    return true
  end,
})
preload("maxa.abilities.hooks.fire", {
  get_bufnr_from_req = function()
    return nil
  end,
})
preload("maxa.mcphub.utils.config_manager", {
  is_server_disabled = function() return false end,
  is_effective_tool_disabled = function() return false end,
})

local captured
preload("maxa.session.abilities", {
  resolve_tool = function(_, _, ability_name, tool_name)
    return { server_name = ability_name, tool_name = tool_name }
  end,
})
local transport = {
  resolve = function()
    return { catalog = { servers = setmetatable({}, { __index = function() return { config = {} } end }) } }
  end,
  inspect_server = function(_, _, callback) callback({ connected = true, status = "connected" }, nil) end,
  call_tool = function(_, server_name, tool_name, params, opts)
    captured = { server_name = server_name, tool_name = tool_name, params = params }
    if params.resource then
      opts.callback({
        result = { content = { { type = "resource", resource = { uri = "file://demo", name = "Demo" } } } },
      })
      return
    end
    if params.image then
      opts.callback({ result = { content = { { type = "image", data = "aGk=", mimeType = "image/png" } } } })
      return
    end
    opts.callback({ result = { content = { { type = "text", text = "ok" } } } })
  end,
}
preload("maxa.mcphub", { get_project_transport = function() return transport end })

local tool = require("maxa.interactions.chat.tools.builtin.tools.builtin_run")
local adapter = require("maxa.interactions.chat.tools.builtin.runtime.adapter")
local chat = { messages = {}, opts = { project_root = "/test" } }
local function invoke(command, args, extra)
  local result
  local p = vim.tbl_extend("force", { title = "target result", scope = "tool", command = command, args = args }, extra or {})
  adapter.invoke(tool, { params = p, chat = chat, cwd = "/test", caller = { maxa_ai = { chat = chat } } },
    function(value) result = value end)
  assert(result, "expected immediate target result")
  return result
end
local small = invoke("@demo:echo", '{"small":true}')
assert(small.ok and captured.params.small == true and adapter.content_to_result(small.content) == "ok", small.error)
for _, key in ipairs({ "json_patches", "json", "json_path" }) do
  local old = captured
  local invalid = invoke("@demo:echo", "{}", { [key] = vim.NIL })
  assert(not invalid.ok and invalid.error:find("not supported", 1, true))
  assert(captured == old, "removed injection dispatched")
end
for _, wrapper in ipairs({ "run", "multicall" }) do
  local result = invoke(wrapper, "{}")
  assert(not result.ok and result.error:find("run cannot call " .. wrapper, 1, true))
end
for _, retired in ipairs({ "call", "read_file", "report", "search_skill" }) do
  local result = invoke(retired, "{}")
  assert(not result.ok and result.error:find("Unknown Chat builtin", 1, true))
end
local resource = invoke("@demo:resource", '{"resource":true}')
assert(resource.ok and resource.content[1].type == "resource" and resource.content[1].resource.uri == "file://demo")
local image = invoke("@demo:image", '{"image":true}')
local hint = adapter.content_to_result(image.content)
assert(image.ok and hint:find("/tmp/mcpx_tool_images/", 1, true))
assert(hint:find("analysis_prompt=", 1, true) and hint:find("max_steps=1", 1, true))
print("run_tool_params_resource_image_spec: OK")
