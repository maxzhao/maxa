local limits = require("maxa.session.model_limits")
local token_usage = require("maxa.session.token_usage")

local function assert_equal(expected, actual, message)
  if expected ~= actual then
    error(string.format("%s: expected %s, got %s", message, vim.inspect(expected), vim.inspect(actual)), 2)
  end
end

assert_equal(500000, limits.get_context_window("deepseek-v4-flash"), "DeepSeek V4 Flash context window")
assert_equal(384000, limits.get_max_output_tokens("deepseek-v4-flash"), "DeepSeek V4 Flash max output")
assert_equal(384000, limits.get_max_output_tokens("DEEPSEEK-V4-PRO"), "model matching is case insensitive")
assert_equal(nil, limits.get_max_output_tokens("deepseek-unknown"), "family fallback must not invent output limits")
assert_equal(128000, limits.get_warning_threshold("chatgpt-4o"), "warning threshold defaults to context window")

local deepseek_adapter = {
  name = "deepseek",
  model = { name = "deepseek-v4-flash" },
}
assert_equal(
  500000,
  token_usage.get_context_window({ adapter = deepseek_adapter }),
  "token usage consumes centralized model context"
)

assert(
  limits.set_model_limit(
    "^test%-model$",
    { context_window = 1234, warning_threshold = 1000, max_output_tokens = 321 }
  )
)
assert_equal(1234, limits.get_context_window("test-model"), "runtime model context override")
assert_equal(1000, limits.get_warning_threshold("test-model"), "runtime warning threshold override")
assert_equal(321, limits.get_max_output_tokens("test-model"), "runtime model output override")

print("model_limits_test: OK")
