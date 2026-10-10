-- filepath: lua/maxa/session/tools/probe_messages_test.lua
-- 运行方式: nvim --headless -l lua/maxa/session/tools/probe_messages_test.lua

local compaction_messages = require("maxa.session.compaction_messages")
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

local probe_messages = require("maxa.session.tools.probe_messages")
local analyze_partitions = probe_messages._test.analyze_partitions

print("\n=== Testing probe_messages partition analysis ===\n")

test("initial protected prefix inference should not lock restored history", function()
  local messages = {
    { role = "system", content = "system prompt", _meta = { tag = "system_prompt_from_config" } },
    { role = "user", content = "rules", _meta = { tag = "rules" } },
    { role = "user", content = "不要思考，直接回复`ok`，不要有任何多余字符。", _meta = { tag = "default_session_cache_warmup" } },
    { role = "llm", content = "ok", _meta = { tag = "default_session_cache_warmup_response" } },
    { role = "user", content = "old task" },
    { role = "llm", content = "old answer" },
    { role = "user", content = "restored active task" },
  }

  assert_eq(2, compaction_messages.infer_initial_protected_prefix_count(messages), "only system/rules prefix is protected")
end)

test("should keep first partition zero-based id and one-based range", function()
  local messages = {
    { role = "system", content = "system prompt", _meta = { tag = "system_prompt_from_config" } },
    { role = "user", content = "rule", _meta = { tag = "rules" } },
    { role = "user", content = "task A" },
    { role = "llm", content = "answer A" },
  }

  local result = analyze_partitions(messages, { messages = messages, compact_protected_prefix_count = 2 })
  assert_true(#result.partitions >= 2, "should create at least initial and tail partitions")
  local first = result.partitions[1]
  assert_eq(0, first.id, "first partition id")
  assert_eq(1, first.start_index, "first partition one-based start")
  assert_eq(2, first.end_index, "protected prefix end")
  assert_eq(0, first.start_offset, "first partition zero-based offset")
  assert_eq("initial_prefix", first.kind, "first kind")
  assert_true(vim.tbl_contains(first.flags, "protected_prefix"), "protected prefix flag")
end)

test("should keep current Ability context tags in the initial partition", function()
  local messages = {
    { role = "system", content = "system prompt", _meta = { tag = "system_prompt_from_config" } },
    { role = "user", content = "revision", _meta = { tag = "ability_revision" } },
    { role = "user", content = "instructions", _meta = { tag = "ability_instructions" } },
    { role = "user", content = "guidance", _meta = { tag = "ability_guidance" } },
    { role = "tool", content = "catalog", _meta = { tag = "ability_catalog" } },
    { role = "user", content = "real task" },
  }

  local result = analyze_partitions(messages, { messages = messages })
  assert_true(#result.partitions >= 2, "should split Ability context from the active tail")
  local initial = result.partitions[1]
  assert_eq("initial_prefix", initial.kind, "Ability context remains in initial prefix")
  assert_eq(5, initial.end_index, "all current Ability context tags remain protected")
end)

test("should detect warmup partition as second partition", function()
  local messages = {
    { role = "system", content = "system prompt", _meta = { tag = "system_prompt_from_config" } },
    { role = "user", content = "不要思考，直接回复`ok`，不要有任何多余字符。", _meta = { tag = "default_session_cache_warmup" } },
    { role = "llm", content = "ok", _meta = { tag = "default_session_cache_warmup_response" } },
    { role = "user", content = "real task" },
    { role = "llm", content = "real answer" },
  }

  local result = analyze_partitions(messages, { messages = messages })
  assert_true(#result.partitions >= 3, "should create initial, warmup and tail partitions")
  local warmup = result.partitions[2]
  assert_eq(1, warmup.id, "warmup partition id")
  assert_eq("warmup", warmup.kind, "warmup kind")
  assert_true(vim.tbl_contains(warmup.flags, "warmup_ok"), "warmup ok flag")
  assert_eq(2, warmup.start_index, "warmup start")
  assert_eq(3, warmup.end_index, "warmup end")
end)

test("single-partition session should keep initial kind and active tail flag", function()
  local messages = {
    { role = "system", content = "system prompt", _meta = { tag = "system_prompt_from_config" } },
  }

  local result = analyze_partitions(messages, { messages = messages })
  assert_eq(1, #result.partitions, "single partition count")
  local only = result.partitions[1]
  assert_eq(0, only.id, "single partition id")
  assert_eq("initial_prefix", only.kind, "single partition keeps initial kind")
  assert_true(vim.tbl_contains(only.flags, "active_tail"), "single partition also tail flag")
end)

test("should report byte percentages across partitions", function()
  local messages = {
    { role = "system", content = "system" },
    { role = "user", content = string.rep("a", 100) },
    { role = "llm", content = string.rep("b", 200) },
    { role = "user", content = "tail" },
  }

  local result = analyze_partitions(messages, { messages = messages })
  local total_percent = 0
  for _, part in ipairs(result.partitions) do
    assert_true(type(part.bytes) == "number" and part.bytes > 0, "partition bytes")
    assert_true(type(part.bytes_percent) == "number", "partition percent")
    total_percent = total_percent + part.bytes_percent
  end
  assert_true(total_percent > 99 and total_percent < 101, "percentages should sum around 100")
end)

print(string.format("\n=== Results: %d passed, %d failed ===\n", passed, failed))
if failed > 0 then
  os.exit(1)
else
  os.exit(0)
end
