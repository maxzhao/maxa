-- filepath: tests/history/write-failure.lua
--- history/write-failure: injected atomic-write failure must preserve old durable
--- state, leave NO partial file, never report saved, and keep the index untouched;
--- a session-commit-success / index-failure must yield saved-index-stale with a
--- deterministic rebuild path; failure is visible (non-empty error string).

local assert_mod = require("tests.history.lib.assert")
local fixture_project = require("tests.history.lib.fixture_project")
local history = require("maxa.runtime.history")

local ctx = assert_mod.new()

fixture_project.with_project(function(proj)
  local st = history.storage.new({ root = proj.root })
  local save_id = "20260806_120000_001_000001_wfail"

  local function make_env(generation, text, updated_at)
    return {
      schema_version = 1,
      session_id = "sess-w",
      save_id = save_id,
      project_id = "proj-1",
      parent_session_id = nil,
      created_at = 1,
      updated_at = updated_at,
      title = nil,
      provider_id = "mock",
      protocol = "mock",
      model = "mock-model",
      messages = { { role = "user", content = { { type = "text", text = text } } } },
      context_items = {},
      runtime_state = { generation = generation, cwd = proj.root, project_root = proj.root },
      trace = { id = nil, membership = {} },
      status_snapshot = {},
    }
  end

  -- 基线：gen1 已保存。
  local base = st:save(make_env(1, "old message", 100))
  ctx.check(base.ok == true, "baseline save ok")
  local chat_path = proj.history_dir .. "/chats/" .. save_id .. ".json"
  local index_path = st.index_path

  -- 场景 1：会话文件原子写注入失败。
  st.inject = { fail_atomic_write_for = { [chat_path] = true } }
  local r = st:save(make_env(2, "new message", 200))
  ctx.check(r.ok == false, "write failure returns ok=false")
  ctx.assert_eq(r.code, "write_failed", "write failure code")
  ctx.check(type(r.error) == "string" and #r.error > 0, "failure visible (non-empty error)")
  ctx.assert_eq(r.status, "write_failed", "status write_failed")

  -- 无部分文件；旧持久状态原样；index 未更新。
  local leftovers = vim.fn.glob(proj.history_dir .. "/chats/*.tmp*", false, true)
  ctx.check(#leftovers == 0, "no partial temp files")
  local durable, derr = st:load_chat(save_id)
  ctx.check(durable ~= nil and derr == nil, "durable chat still readable")
  if durable then
    ctx.assert_eq(durable.messages[1].content[1].text, "old message", "old durable content preserved")
    ctx.assert_eq(durable.runtime_state.generation, 1, "durable generation unchanged")
  end
  local idx = st:get_chats()
  ctx.check(idx[save_id] ~= nil, "index entry still present")
  if idx[save_id] then
    ctx.assert_eq(idx[save_id].message_count, 1, "index not updated (old count)")
    ctx.assert_eq(idx[save_id].updated_at, 100, "index not updated (old updated_at)")
  end

  -- 场景 2：会话提交成功、index 写入失败 -> saved-index-stale，会话保留。
  st.inject = { fail_atomic_write_for = { [index_path] = true } }
  local r2 = st:save(make_env(2, "new message", 200))
  ctx.check(r2.ok == false, "index failure returns ok=false")
  ctx.assert_eq(r2.code, "index_stale", "index failure code")
  ctx.assert_eq(r2.status, "saved-index-stale", "saved-index-stale status")
  ctx.assert_eq(r2.save_id, save_id, "stale result carries save_id")
  ctx.check(type(r2.error) == "string" and #r2.error > 0, "index failure visible")

  local committed = st:load_chat(save_id)
  if committed then
    ctx.assert_eq(committed.messages[1].content[1].text, "new message", "session file committed despite index failure")
    ctx.assert_eq(committed.runtime_state.generation, 2, "committed generation")
  end
  local idx2 = st:get_chats()
  ctx.assert_eq(idx2[save_id].message_count, 1, "index still stale after commit")

  -- 确定性重建修复 index（以已提交的 gen2 内容为准：1 条消息、updated_at 200）。
  -- 重建前清除注入：否则 index 写仍被注入失败（rebuild 会在 result.error 上报）。
  st.inject = nil
  local rb = st:rebuild_index()
  ctx.assert_eq(rb.rebuilt, 1, "rebuild rebuilt 1 chat")
  ctx.assert_eq(#rb.skipped, 0, "rebuild skipped nothing")
  local rebuilt_entry = st:get_chats()[save_id]
  ctx.check(rebuilt_entry ~= nil, "index rebuilt entry present")
  if rebuilt_entry then
    ctx.assert_eq(rebuilt_entry.message_count, 1, "index rebuilt with committed content")
    ctx.assert_eq(rebuilt_entry.updated_at, 200, "index rebuilt with committed updated_at")
  end

  -- 场景 3：fail_next_write 风格（下一次原子写失败 = 会话写失败）。
  st.inject = { fail_next_write = 1 }
  local r3 = st:save(make_env(3, "next message", 300))
  ctx.check(r3.ok == false, "fail_next_write fails the next write")
  ctx.assert_eq(r3.code, "write_failed", "fail_next_write code")
  local durable3 = st:load_chat(save_id)
  if durable3 then
    ctx.assert_eq(durable3.messages[1].content[1].text, "new message", "gen3 not persisted")
  end
end)

if not ctx.ok then
  error("write-failure failed: " .. table.concat(ctx.failures, "; "), 0)
end
print("HISTORY_OK: write-failure")
