-- Direct wrapper-bypass guard tests for hidden image-analysis children.
-- Run: nvim --headless -u NONE -l lua/maxa/interactions/chat/tools/builtin/tests/tool_call_core_guard_test.lua
package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path
package.loaded["plenary.path"] = {
  new = function()
    return { exists = function() return false end, is_dir = function() return false end }
  end,
}
package.loaded["maxa.interactions.chat.tools.builtin.runtime.utils"] = {
  MAX_OUTPUT_CHARS = 1000, MAX_ERROR_OUTPUT_CHARS = 1000,
  validate_required_string = function(value)
    return type(value) == "string" and value ~= "", nil
  end,
}

local core = require("maxa.interactions.chat.tools.builtin.runtime.tool_call_core")
local req = { caller = { maxa_ai = { chat = { _maxa_hidden_image_analysis = true } } } }
for _, name in ipairs({
  "analyze",
  "multicall",
  "@subagent:run_agent",
  "@subagent:fork_agent",
  "@subagent:resume_agent",
  "@subagent:multi_agent",
}) do
  local err = core.hidden_image_analysis_guard(req, name)
  assert(type(err) == "string" and err:find("cannot call", 1, true), name .. " was not blocked")
end
assert(core.hidden_image_analysis_guard(req, "read") == nil)
assert(core.hidden_image_analysis_guard({ caller = { maxa_ai = { chat = {} } } }, "@subagent:run_agent") == nil)
print("tool_call_core_guard_test: OK")
