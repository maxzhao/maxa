-- filepath: lua/maxa/interactions/chat/tools/builtin/tests/call_tool_async_cancel_spec.lua
package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path

_G.vim = _G.vim or {}
vim.fn = vim.fn or {}
vim.fn.stdpath = function() return vim.loop and vim.loop.cwd() or assert(io.popen("pwd")):read("*l") end
vim.fn.timer_start = vim.fn.timer_start or function(_, _) return 1 end
vim.fn.timer_stop = vim.fn.timer_stop or function(_) return 1 end
vim.trim = vim.trim or function(s) return tostring(s):match("^%s*(.-)%s*$") end
vim.inspect = vim.inspect or tostring
vim.json = vim.json or require("vim.json")
vim.uv = vim.uv or vim.loop
vim.deepcopy = vim.deepcopy or function(value)
  if type(value) ~= "table" then return value end
  local copy = {}
  for k, v in pairs(value) do copy[k] = vim.deepcopy(v) end
  return copy
end
vim.tbl_isempty = vim.tbl_isempty or function(tbl) return next(tbl) == nil end

local function preload(name, value) package.loaded[name] = value end
preload("plenary.path", {})
preload("maxa.interactions.chat.tools.builtin.runtime.utils", {
  MAX_OUTPUT_CHARS = 100000,
  MAX_ERROR_OUTPUT_CHARS = 4096,
  MAX_ERROR_PREVIEW_CHARS = 2048,
  validate_required_string = function(value, field)
    if type(value) ~= "string" or value == "" then return false, field .. " is required" end
    return true
  end,
})
preload("maxa.abilities.hooks.fire", { get_bufnr_from_req = function() return nil end })
preload("maxa.mcphub.utils.config_manager", {
  is_server_disabled = function() return false end,
  is_effective_tool_disabled = function() return false end,
})

local pending_callback = nil
local handle_cancelled = 0
preload("maxa.session.abilities", {
  resolve_tool = function(_, _, ability_name, tool_name)
    assert(ability_name == "subagent" and tool_name == "run_agent")
    return { server_name = ability_name, tool_name = tool_name }
  end,
})
local transport = {
  resolve = function() return { catalog = { servers = { subagent = { config = {} } } } } end,
  inspect_server = function(_, _, callback) callback({ connected = true, status = "connected" }, nil) end,
  call_tool = function(_, _, _, _, opts)
    local bridge = require("maxa.interactions.chat.tools.builtin.runtime.async_cancel_bridge")
    bridge.register_handle({
      kind = "test_inner",
      cancel = function(reason)
        handle_cancelled = handle_cancelled + 1
        assert(reason:match("cancel"), "cancel reason should mention cancel_async_task")
      end,
    })
    pending_callback = opts.callback
  end,
}
preload("maxa.mcphub", { get_project_transport = function() return transport end })

local call_tool = require("maxa.interactions.chat.tools.builtin.tools.builtin_run")
local adapter = require("maxa.interactions.chat.tools.builtin.runtime.adapter")
local cancel_tool = require("maxa.interactions.chat.tools.builtin.tools.builtin_kill")
local get_result = require("maxa.interactions.chat.tools.builtin.tools.builtin_wait")

local function response()
  local texts = {}
  return {
    texts = texts,
    text = function(self, text) table.insert(texts, text); return self end,
    send = function(self) self.sent = true; return self end,
    error = function(self, text) self.error_text = text; return self end,
  }
end

local function assert_eq(actual, expected, label)
  if actual ~= expected then error(string.format("%s: expected %s, got %s", label, tostring(expected), tostring(actual))) end
end
local function assert_true(value, label) if not value then error(label or "expected truthy value") end end

local res = response()
local chat = { messages = {}, opts = { project_root = "/test" } }
adapter.invoke(call_tool, {
  params = { title = "child", scope = "tool", command = "@subagent:run_agent", args = "{}", opts = '{"async":true}' },
  chat = chat,
  cwd = "/test",
  caller = { maxa_ai = { chat = chat } },
}, function(result)
  if result.ok then res:text(adapter.content_to_result(result.content)):send() else res:error(result.error) end
end)
assert_true(res.sent, res.error_text or "async submit sent")
local submit = { async_id = res.texts[1]:match("async_id: ([^\n]+)") }
assert_true(submit.async_id and submit.async_id:match("^async_"), "async id")
assert_true(res.texts[1]:find("lifetime: current Neovim session",1,true), "session lifetime retained")
assert_true(pending_callback ~= nil, "inner call deferred")

local cancel_res = response()
cancel_tool.run({ params = { title = "cancel child", async_id = submit.async_id } }, cancel_res)
local cancelled = { status = cancel_res.texts[1]:match("status: ([^\n]+)") }
assert_eq(cancelled.status, "cancelled", "cancel status")
assert_eq(handle_cancelled, 1, "inner handle cancelled")

pending_callback({ result = { content = { { type = "text", text = "late result" } } } })
local check = response()
get_result.run({ params = { title = "Check cancelled call", async_id = submit.async_id, mode = "try" } }, check)
local final = { status = check.texts[1]:match("status: ([^\n]+)") }
assert_eq(final.status, "cancelled", "late callback ignored")

print("call_tool_async_cancel_spec: OK")
