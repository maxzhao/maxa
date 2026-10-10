-- Test clone_messages_with_truncation behavior.
-- Run with: nvim --headless -u NONE -l lua/maxa/session/slash_commands/compact_utils_clone_truncation_test.lua

package.path = table.concat({
  vim.fn.getcwd() .. "/lua/?.lua",
  vim.fn.getcwd() .. "/lua/?/init.lua",
  package.path,
}, ";")

local compact_utils = require("maxa.session.slash_commands.compact_utils")

local function assert_eq(actual, expected, message)
  if actual ~= expected then
    error(string.format("%s\nexpected: %s\nactual: %s", message or "assertion failed", vim.inspect(expected), vim.inspect(actual)), 2)
  end
end

local long_text = string.rep("x", 80)
local messages = {
  { role = "system", content = long_text },
  { role = "user", content = long_text },
  { role = "assistant", content = long_text },
  { role = "llm", content = long_text },
  { role = "tool", content = long_text },
}

local cloned = compact_utils.clone_messages_with_truncation(messages, 10)

assert_eq(cloned[1].content, long_text, "system content should not be truncated")
assert_eq(cloned[2].content, long_text, "user content should not be truncated")
assert_eq(cloned[3].content, long_text, "assistant content should not be truncated")
assert_eq(cloned[4].content, long_text, "llm content should not be truncated")

if not cloned[5].content:match("%[已截断") then
  error("tool content should still be truncated")
end

if cloned[3] == messages[3] then
  error("messages should be deep-copied, not reused")
end

print("compact_utils_clone_truncation_test: OK")
