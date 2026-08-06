-- filepath: tests/history/legacy-refs-migration.lua
--- history/legacy-refs-migration: missing schema_version = legacy input; known
--- fields parsed; refs normalized to context_items exactly once (never 'refs' in
--- v1); tool-argument JSON + UTF-8 sanitized; backup .bak written; v1 written
--- atomically only after successful migration; schema_version>1 fails closed
--- without rewrite; garbage isolated without deletion; second migrate is a no-op.

local assert_mod = require("tests.history.lib.assert")
local fixture_project = require("tests.history.lib.fixture_project")
local history = require("maxa.runtime.history")

local ctx = assert_mod.new()

local function write_raw(path, text)
  local fh = assert(io.open(path, "wb"))
  fh:write(text)
  fh:close()
end

local function read_raw(path)
  local fh = assert(io.open(path, "rb"))
  local body = fh:read("*a")
  fh:close()
  return body
end

-- 手工构造 legacy JSON（含无效 UTF-8 原始字节，验证解码+消毒路径）。
local legacy_json = table.concat({
  "{",
  '"save_id":"20250101_100000_001_000001_legacy1",',
  '"title":"Legacy Chat",',
  '"adapter":"anthropic",',
  '"settings":{"model":"claude-3-5-sonnet"},',
  '"updated_at":1700000000,',
  '"cycle":3,',
  '"compact_protected_prefix_count":2,',
  '"cwd":"/tmp/legacy-proj",',
  '"project_root":"/tmp/legacy-proj",',
  '"refs":[{"id":"ref-1","type":"file","path":"README.md"}],',
  '"messages":[',
  '{"role":"user","content":"hello \128\129 legacy"},',
  '{"role":"llm","tools":{"calls":[{"function":{"name":"read_file","arguments":"{invalid json"}}]}},',
  '{"role":"llm","tools":{"calls":[{"function":{"name":"list","arguments":{"a":1}}}]}}',
  "]",
  "}",
})

fixture_project.with_project(function(proj)
  local st = history.storage.new({ root = proj.root })
  local legacy_path = proj.history_dir .. "/chats/20250101_100000_001_000001_legacy1.json"
  write_raw(legacy_path, legacy_json)

  local res = history.migrate.migrate_file(st, legacy_path)
  ctx.check(res.ok == true, "migrate ok")
  ctx.assert_eq(res.save_id, "20250101_100000_001_000001_legacy1", "migrate save_id")

  -- .bak 存在且与原始内容一致。
  ctx.check(vim.fn.filereadable(legacy_path .. ".bak") == 1, ".bak written")
  ctx.assert_eq(read_raw(legacy_path .. ".bak"), legacy_json, ".bak preserves original")

  -- v1 信封：refs -> context_items；无 refs 键；标量字段映射；消毒生效。
  local env, err = st:load_chat("20250101_100000_001_000001_legacy1")
  ctx.check(env ~= nil and err == nil, "migrated chat loads as v1")
  if env then
    ctx.assert_eq(env.schema_version, 1, "schema_version 1")
    ctx.assert_eq(env.refs, nil, "no refs key in v1 envelope")
    ctx.assert_same_table(
      env.context_items,
      { { id = "ref-1", type = "file", path = "README.md" } },
      "refs normalized to context_items"
    )
    ctx.assert_eq(env.provider_id, "anthropic", "provider_id from adapter")
    ctx.assert_eq(env.model, "claude-3-5-sonnet", "model from settings")
    ctx.assert_eq(env.title, "Legacy Chat", "title preserved")
    ctx.assert_eq(env.runtime_state.cycle, 3, "cycle preserved")
    ctx.assert_eq(env.runtime_state.compact_protected_prefix_count, 2, "compact count preserved")
    ctx.assert_eq(env.runtime_state.cwd, "/tmp/legacy-proj", "cwd preserved")
    ctx.assert_eq(env.runtime_state.project_root, "/tmp/legacy-proj", "project_root preserved")
    -- UTF-8 消毒：两个无效字节 -> 两个 U+FFFD。
    ctx.assert_eq(
      env.messages[1].content,
      "hello \239\191\189\239\191\189 legacy",
      "invalid UTF-8 replaced with U+FFFD"
    )
    -- 工具参数消毒：非法 JSON 字符串 -> "{}"；非字符串 -> JSON 编码。
    ctx.assert_eq(env.messages[2].tools.calls[1]["function"].arguments, "{}", "invalid tool args JSON -> {}")
    ctx.assert_eq(env.messages[3].tools.calls[1]["function"].arguments, '{"a":1}', "non-string tool args JSON-encoded")
  end

  -- refs 归一恰一次：再次迁移是幂等 no-op，不重写、不重复备份。
  local res2 = history.migrate.migrate_file(st, legacy_path)
  ctx.check(res2.ok == true, "second migrate ok (idempotent)")
  ctx.assert_eq(res2.save_id, "20250101_100000_001_000001_legacy1", "second migrate save_id")
  local env2, _ = st:load_chat("20250101_100000_001_000001_legacy1")
  ctx.assert_eq(env2.context_items[1].id, "ref-1", "context_items not duplicated on re-migrate")

  -- schema_version=2 -> runtime-upgrade-required，不重写。
  local v2_path = proj.history_dir .. "/chats/v2chat.json"
  local v2_body = vim.json.encode({
    schema_version = 2,
    save_id = "v2chat",
    messages = {},
  })
  write_raw(v2_path, v2_body)
  local rv2 = history.migrate.migrate_file(st, v2_path)
  ctx.check(rv2.ok == false, "v2 migrate rejected")
  ctx.assert_eq(rv2.code, "runtime-upgrade-required", "v2 code")
  ctx.assert_eq(read_raw(v2_path), v2_body, "v2 file NOT rewritten")

  -- garbage -> corrupt 隔离，文件保留。
  local garbage_path = proj.history_dir .. "/chats/garbage.json"
  write_raw(garbage_path, "not json {{{ garbage")
  local rg = history.migrate.migrate_file(st, garbage_path)
  ctx.check(rg.ok == false, "garbage migrate rejected")
  ctx.assert_eq(rg.code, "corrupt", "garbage code")
  ctx.check(type(rg.error) == "string" and #rg.error > 0, "corrupt error has reason")
  ctx.check(vim.fn.filereadable(garbage_path) == 1, "garbage file preserved")
  ctx.assert_eq(read_raw(garbage_path), "not json {{{ garbage", "garbage file unchanged")
end)

if not ctx.ok then
  error("legacy-refs-migration failed: " .. table.concat(ctx.failures, "; "), 0)
end
print("HISTORY_OK: legacy-refs-migration")
