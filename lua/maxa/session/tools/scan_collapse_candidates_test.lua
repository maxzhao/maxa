-- filepath: lua/maxa/session/tools/scan_collapse_candidates_test.lua
-- 运行方式: nvim --headless -l lua/maxa/session/tools/scan_collapse_candidates_test.lua

local passed = 0
local failed = 0

local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then
    passed = passed + 1
    print("✓ " .. name)
  else
    failed = failed + 1
    print("✗ " .. name)
    print("  Error: " .. tostring(err))
  end
end

local function assert_true(value, msg)
  if not value then
    error(msg or "expected true")
  end
end

local function assert_eq(expected, actual, msg)
  if expected ~= actual then
    error(string.format("%s: expected %s, got %s", msg or "assertion failed", tostring(expected), tostring(actual)))
  end
end

local function assert_nil(value, msg)
  if value ~= nil then
    error((msg or "expected nil") .. ": got " .. tostring(value))
  end
end

local scan = require("maxa.session.tools.scan_collapse_candidates")

local function sample_messages()
  return {
    { role = "user", content = "m1 stable" },
    { role = "assistant", content = "m2 stable" },
    {
      role = "assistant",
      tools = {
        calls = {
          {
            id = "call-load-ability",
            ["function"] = {
              name = "load",
              arguments = vim.json.encode({ target = "task-admin" }),
            },
          },
        },
      },
    },
    { role = "tool", content = "loaded Ability ok", tools = { call_id = "call-load-ability" } },
    {
      role = "user",
      content = "Ability revision content that must not be returned as snippet",
      context = { id = "ability:revision:task-admin" },
      _meta = { tag = "ability_revision", ability = { kind = "revision", name = "task-admin", catalog_call_id = "call-load-ability" } },
    },
    { role = "user", content = "ordinary current request" },
    {
      role = "assistant",
      tools = {
        calls = {
          {
            id = "call-rg",
            ["function"] = {
              name = "execute_command",
              arguments = vim.json.encode({ command = "rg test" }),
            },
          },
        },
      },
    },
    { role = "tool", content = "**`execute_command` Tool**: Failed with the following error:", tools = { call_id = "call-rg" } },
  }
end

local function walk(value, fn)
  fn(value)
  if type(value) == "table" then
    for _, child in pairs(value) do
      walk(child, fn)
    end
  end
end

print("\n=== Testing scan_collapse_candidates ===\n")

test("build_candidates scans collapse_start_index..last and preserves original indices", function()
  local data, err = scan.build_candidates(sample_messages(), 3)
  assert_true(not err, err)
  assert_eq(3, data.range.collapse_start_index, "range start")
  assert_eq(8, data.range.collapse_end_index, "range end")
  assert_eq(6, data.counts.total, "range message count")
  assert_eq(1, data.counts.context, "context count")
  assert_eq(2, data.counts.tool_call_messages, "tool call message count")
  assert_eq(2, data.counts.tool_result_messages, "tool result message count")
end)

test("loaded Ability candidate includes call/result/context indices without snippets or reasons", function()
  local data, err = scan.build_candidates(sample_messages(), 3)
  assert_true(not err, err)
  local loaded = data.candidates.loaded_items[1]
  assert_eq("load", loaded.item_type, "item type")
  assert_eq("task-admin", loaded.value, "value")
  assert_eq(3, loaded.call_indices[1], "call index")
  assert_eq(4, loaded.result_indices[1], "result index")
  assert_eq(5, loaded.context_indices[1], "context index")

  walk(data, function(node)
    if type(node) == "table" then
      assert_nil(node.reason, "reason must not be returned")
      assert_nil(node.snippet, "snippet must not be returned")
      assert_nil(node.content, "content must not be returned")
    end
  end)
end)

test("tool result facts include status and paired tool name", function()
  local data, err = scan.build_candidates(sample_messages(), 3)
  assert_true(not err, err)
  local failed_result = data.candidates.tool_result_messages[2]
  assert_eq(8, failed_result.index, "result index")
  assert_eq("error", failed_result.status, "tool status")
  assert_eq("execute_command", failed_result.tool_name, "tool name")
  assert_eq(7, failed_result.call_index, "call index")
end)

test("collapse_start_index must be before last message", function()
  local _, err = scan.build_candidates(sample_messages(), 8)
  assert_true(err and err:match("< last message index"), "expected invalid start error")
end)

print(string.format("\n=== Results: %d passed, %d failed ===\n", passed, failed))
if failed > 0 then
  os.exit(1)
else
  os.exit(0)
end
