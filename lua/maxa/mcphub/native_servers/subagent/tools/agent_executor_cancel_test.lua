-- filepath: lua/maxa/mcphub/native_servers/subagent/tools/agent_executor_cancel_test.lua
-- Run with: nvim --headless -u NONE -l lua/maxa/mcphub/native_servers/subagent/tools/agent_executor_cancel_test.lua
package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path

_G.vim = _G.vim or {}
vim.schedule = vim.schedule or function(fn) fn() end
vim.defer_fn = vim.defer_fn or function(fn, _) fn() end
vim.trim = vim.trim or function(s) return tostring(s):match("^%s*(.-)%s*$") end
vim.tbl_isempty = vim.tbl_isempty or function(tbl) return next(tbl) == nil end
vim.json = vim.json or require("vim.json")
vim.api = vim.api or {}
vim.api.nvim_buf_is_valid = function() return false end

package.loaded["maxa.session.session_status"] = {
  from_chat = function() return {} end,
  to_llm = function(status) return status end,
}
package.loaded["maxa.mcphub.native_servers.subagent.utils"] = {
  normalize_max_turns = function(v, default) return v == 0 and math.huge or (v or default) end,
  get_chat_save_id = function() return "save-test" end,
  extract_final_response = function() return "final" end,
}
package.loaded["maxa.mcphub.native_servers.subagent.tools.window_manager"] = {
  is_interrupted = function() return false end,
  reset_interrupted = function() end,
}

local async_cancel = require("maxa.mcphub.native_servers.subagent.async_cancel")
local executor = require("maxa.mcphub.native_servers.subagent.tools.agent_executor")

local function assert_eq(actual, expected, label)
  if actual ~= expected then error(string.format("%s: expected %s, got %s", label, tostring(expected), tostring(actual))) end
end
local function assert_true(value, label) if not value then error(label or "expected truthy value") end end

local function new_chat()
  return {
    callbacks = {},
    messages = {},
    submitted = 0,
    submit = function(self)
      self.submitted = self.submitted + 1
    end,
    done = function() end,
  }
end

local chat = new_chat()
async_cancel.mark_cancelled(chat, "pre-cancel")
local err
executor.execute({
  chat = chat,
  on_error = function(e) err = e end,
})
vim.wait(100, function() return err ~= nil or chat.submitted > 0 end, 5)
assert_eq(chat.submitted, 0, "pre-cancel should not submit")
assert_true(err and err:find("pre-cancel", 1, true), "pre-cancel error returned: " .. tostring(err))

chat = new_chat()
local completed
err = nil
executor.execute({
  chat = chat,
  on_complete = function() completed = true end,
  on_error = function(e) err = e end,
})
vim.wait(100, function() return chat.submitted == 1 end, 5)
assert_eq(chat.submitted, 1, "normal initial submit")
async_cancel.mark_cancelled(chat, "boundary-cancel")
chat.callbacks.on_completed[1](chat)
assert_eq(completed, nil, "cancel boundary should not complete normally")
assert_true(err and err:find("boundary-cancel", 1, true), "boundary cancel error: " .. tostring(err))

-- Replacement keeps one invocation and retires old callbacks/timers. This is
-- executor-only coverage; live Chat identity/interaction is checked separately.
local source, successor = new_chat(), new_chat()
local completions, errors = 0, 0
executor.execute({
  chat = source,
  max_turns = 3,
  on_complete = function(result)
    completions = completions + 1
    assert_eq(result.turns_used, 2, "turn budget survives replacement")
  end,
  on_error = function() errors = errors + 1 end,
})
vim.wait(100, function() return source.submitted == 1 end, 5)
source.messages = { { tool_calls = { {} } } }
local late_completion = source.callbacks.on_completed[1]
late_completion(source)
assert_true(source._subagent_executor.replace(successor), "replacement accepted")
assert_eq(#source.callbacks.on_closed, 0, "old close does not terminate invocation")
late_completion(source)
assert_eq(completions, 0, "retired source cannot complete")
vim.wait(100, function() return successor.submitted == 1 end, 5)
successor.messages = { { role = "assistant", content = "final" } }
successor.callbacks.on_completed[1](successor)
vim.wait(1500, function() return completions == 1 end, 5)
assert_eq(completions, 1, "successor completes once")
assert_eq(errors, 0, "source retirement is not an error")
assert_eq(successor._subagent_executor.finished, true, "invocation terminal")

print("agent_executor_cancel_test: OK")
