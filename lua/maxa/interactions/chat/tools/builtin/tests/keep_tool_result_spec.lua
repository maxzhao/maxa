-- filepath: lua/maxa/interactions/chat/tools/builtin/tests/keep_tool_result_spec.lua
-- Run: nvim --headless -u NONE -l lua/maxa/interactions/chat/tools/builtin/tests/keep_tool_result_spec.lua
package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path

local ttl_module = "maxa.interactions.chat.tools.builtin.runtime.ttl_result"
local ability_module = "maxa.interactions.chat.tools.builtin.runtime.ability_utils"
package.loaded[ttl_module] = {
  apply_action = function(_, tool_call_id, action)
    return true, action .. " " .. tool_call_id
  end,
}
package.loaded[ability_module] = {
  get_chat_and_agent = function()
    return {}
  end,
}

local tool = require("maxa.interactions.chat.tools.builtin.tools.builtin_keep")

local function response()
  return {
    text = function(self, value)
      self.text_value = value
      return self
    end,
    error = function(self, value)
      self.error_text = value
      return self
    end,
    send = function(self)
      self.sent = true
      return self
    end,
  }
end

local required = {}
for _, name in ipairs(tool.inputSchema.required or {}) do
  required[name] = true
end
assert(required.title, "schema requires title")
assert(tool.inputSchema.properties.title.type == "string", "title schema type")

local res = response()
tool.run({ params = { tool_call_id = "call-1", action = "keep" } }, res)
assert(res.error_text and res.error_text:find("title parameter is required", 1, true), "missing title rejected")

res = response()
tool.run({ params = { title = "   ", tool_call_id = "call-1", action = "keep" } }, res)
assert(res.error_text and res.error_text:find("title parameter cannot be empty", 1, true), "blank title rejected")

res = response()
tool.run({ params = { title = "Preserve result", tool_call_id = "call-1", action = "keep" } }, res)
assert(res.sent, "valid call sends response")
assert(res.text_value == "✅ keep call-1", "valid call preserves lifecycle behavior")

print("keep_tool_result_spec: OK")
