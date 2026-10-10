-- Run: nvim --headless -u NONE -l lua/maxa/interactions/chat/tools/validator_test.lua
vim.opt.runtimepath:prepend(vim.fn.getcwd())
for _, dependency in ipairs({ "plenary.nvim", "nui.nvim" }) do
  local path = vim.fn.stdpath("data") .. "/lazy/" .. dependency
  if vim.fn.isdirectory(path) == 1 then
    vim.opt.runtimepath:prepend(path)
  end
end
package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path

local adapters = require("maxa.adapters")
local anthropic = require("maxa.adapters.http.anthropic")
local openai = require("maxa.adapters.http.openai")
local responses = require("maxa.adapters.http.openai_responses")
local validator = require("maxa.interactions.chat.tools.validator")

local function unicode_len(value)
  return vim.fn.strchars(value)
end

local function call(id, arguments)
  return {
    id = id,
    type = "function",
    thought_signature = "signed-provider-metadata",
    ["function"] = {
      name = "write",
      arguments = arguments,
    },
  }
end

local chat = {
  tool_registry = {
    schemas = {
      ["<tool>write</tool>"] = {
        type = "function",
        ["function"] = {
          name = "write",
          parameters = {
            type = "object",
            properties = {
              path = { type = "string" },
              content = { type = "string" },
            },
            required = { "path", "content" },
          },
        },
      },
    },
  },
}

local valid = call("call-valid", [[{"path":"a","content":"b"}]])
local valid_before = vim.deepcopy(valid)
local result = validator.classify({ adapter = openai }, chat, valid, 1)
assert(result.kind == "valid", "valid OpenAI call was rejected")
assert(vim.deep_equal(valid, valid_before), "validator mutated a valid canonical call")

local missing = call("call-missing", [[{"path":"a"}]])
local missing_before = vim.deepcopy(missing)
result = validator.classify({ adapter = openai }, chat, missing, 1)
assert(result.kind == "rejected_replayable", "missing required field should be replayable for OpenAI")
assert(result.reason_code == "missing_required")
assert(result.feedback:find("rejected_before_execution", 1, true))
assert(result.feedback:find("The tool was not executed", 1, true))
assert(vim.deep_equal(missing, missing_before), "validator mutated a rejected canonical call")

local truncated = call("call-truncated", [[{"path":"a","content":"unfinished]])
local truncated_before = vim.deepcopy(truncated)
result = validator.classify({ adapter = openai }, chat, truncated, 1)
assert(result.kind == "rejected_replayable", "opaque OpenAI arguments should remain replayable")
assert(result.reason_code == "invalid_json")
assert(result.received_chars == unicode_len(truncated["function"].arguments))
assert(unicode_len(result.snapshot) <= 1000, "invalid JSON snapshot exceeded 1000 Unicode characters")
assert(vim.deep_equal(truncated, truncated_before), "invalid JSON call was mutated")

result = validator.classify({ adapter = anthropic }, chat, truncated, 1)
assert(result.kind == "rejected_unreplayable", "invalid Anthropic input must not enter tool_use history")

local anthropic_error = adapters.call_handler(anthropic, "format_response", missing, "rejected", { is_error = true })
assert(anthropic_error.tools.is_error == true, "Anthropic validation result lost is_error=true")

local response_call = call("fc_item", [[{"path":"a"}]])
response_call.call_id = "call_response"
result = validator.classify({ adapter = responses }, chat, response_call, 1)
assert(result.kind == "rejected_replayable", "Responses call with id/call_id should be replayable")

local incomplete_response_call = call("fc_incomplete", [[{"path":"a","content":"b"}]])
incomplete_response_call.call_id = "call_incomplete"
incomplete_response_call._status = "incomplete"
result = validator.classify({ adapter = responses }, chat, incomplete_response_call, 1)
assert(result.kind == "rejected_replayable", "incomplete Responses call should become a paired rejection")
assert(result.reason_code == "incomplete_call")

local missing_id = call(nil, [[{"path":"a"}]])
result = validator.classify({ adapter = openai }, chat, missing_id, 1)
assert(result.kind == "rejected_unreplayable", "call without id must not be replayed")

local field = string.rep("界", 251)
local encoded = vim.json.encode({ path = "a", content = field })
local decoded = vim.json.decode(encoded)
local snapshot = validator.snapshot(encoded, decoded)
assert(unicode_len(snapshot) <= 1000, "structured snapshot exceeded 1000 Unicode characters")
assert(snapshot:find('"content"', 1, true), "structured snapshot lost field names")
assert(snapshot:find("field truncated", 1, true), "251-character field was not truncated")

local large = vim.json.encode({
  a = string.rep("甲", 400),
  b = string.rep("乙", 400),
  c = string.rep("丙", 400),
  d = string.rep("丁", 400),
})
snapshot = validator.snapshot(large, vim.json.decode(large))
assert(unicode_len(snapshot) <= 1000, "multi-field snapshot exceeded 1000 Unicode characters")
assert(snapshot:find("snapshot truncated", 1, true), "overall snapshot did not report truncation")

local raw = string.rep("数", 2000)
snapshot = validator.snapshot(raw, nil, "parse failed")
assert(unicode_len(snapshot) <= 1000, "raw snapshot metadata plus prefix exceeded 1000 Unicode characters")
assert(snapshot:find("received 2000 chars", 1, true), "raw snapshot lost received character count")

for _, invalid in ipairs({
  "bad\255input",
  "bad\224\128\128input",
  "bad\237\160\128input",
  "bad\244\144\128\128input",
}) do
  snapshot = validator.snapshot(invalid, nil, "parse failed")
  assert(snapshot:find("invalid UTF%-8"), "invalid UTF-8 was not replaced with bounded valid text")
  assert(not snapshot:find(invalid, 1, true), "invalid UTF-8 sequence leaked into feedback")
end

local wrong_type = call("type-error", [[{"path":3,"content":"b"}]])
result = validator.classify({ adapter = openai }, chat, wrong_type, 1)
assert(result.kind == "rejected_replayable" and result.reason_code == "invalid_parameters")
assert(result.reason:find("$.path", 1, true))
local null_required = call("null-error", [[{"path":null,"content":"b"}]])
result = validator.classify({ adapter = openai }, chat, null_required, 1)
assert(result.kind == "rejected_replayable" and result.reason_code == "invalid_parameters")
local array_root = call("array-error", "[]")
result = validator.classify({ adapter = openai }, chat, array_root, 1)
assert(result.kind ~= "valid")
-- Whole-response recognition uses original calls, not filtered history.
local function named(name, id, arguments)
  local item = call(id, arguments or "{}")
  item["function"].name = name
  return item
end
local declaration = named("multicall", "declare", '{"title":"batch"}')
local native_calls = { declaration, valid }
local original = vim.deepcopy(native_calls)
local native_plan = validator.classify_batch({ adapter = openai }, chat, native_calls)
assert(native_plan.native_batch and not native_plan.native_batch.error)
assert(vim.deep_equal(native_calls, original), "native declaration mutated original calls")
for _, calls in ipairs({ { declaration }, { valid, declaration }, { declaration, valid, declaration } }) do
  assert(validator.classify_batch({ adapter = openai }, chat, calls).native_batch.error)
end
assert(not validator.classify_batch({ adapter = openai }, chat, { valid }).native_batch)
local malformed_first = named("write", nil, '{"path":"a"}')
local malformed_plan = validator.classify_batch({ adapter = openai }, chat, { malformed_first, declaration, valid })
assert(#malformed_plan.history_calls == 2 and malformed_plan.native_batch.error,
  "unreplayable first call must not turn a misplaced declaration into first position")
local maximum = { declaration }
for index = 1, 16 do maximum[#maximum + 1] = named("read", "member-" .. index) end
assert(not validator.classify_batch({ adapter = openai }, chat, maximum).native_batch.error)
maximum[#maximum + 1] = named("read", "overflow")
assert(validator.classify_batch({ adapter = openai }, chat, maximum).native_batch.error)
local duplicate = vim.deepcopy(valid)
duplicate.id = declaration.id
local conflict_plan = validator.classify_batch({ adapter = openai }, chat, { declaration, duplicate })
assert(conflict_plan.native_batch.error and #conflict_plan.history_calls == 1 and #conflict_plan.corrections == 1)
assert(conflict_plan.entries[2].reason_code == "duplicate_call_id")
print("validator_test: existing 21 cases and native-batch recognition/identity conflicts passed")
