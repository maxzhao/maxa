-- filepath: tests/history/concurrent-save.lua
--- history/concurrent-save: same-save_id saves serialize by generation (stale
--- generation rejected with generation_conflict, never overwrites durable
--- content); independent sessions interleave without losing index entries
--- (index updates re-read the latest index before writing — verified through the
--- inject.before_index_update nested-save race).

local assert_mod = require("tests.history.lib.assert")
local fixture_project = require("tests.history.lib.fixture_project")
local history = require("maxa.runtime.history")

local ctx = assert_mod.new()

fixture_project.with_project(function(proj)
  local st = history.storage.new({ root = proj.root })

  local function make_env(save_id, generation, text, updated_at)
    return {
      schema_version = 1,
      session_id = "sess-" .. save_id,
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

  -- 场景 1：同 save_id 按 generation 串行；stale 拒绝且不覆盖。
  local save_id = "20260806_120000_001_000001_conc"
  local r1 = st:save(make_env(save_id, 1, "gen1", 100))
  ctx.check(r1.ok == true, "gen1 save ok")
  local r2 = st:save(make_env(save_id, 2, "gen2", 200))
  ctx.check(r2.ok == true, "gen2 save ok (wins)")
  local r3 = st:save(make_env(save_id, 1, "gen1-retry", 300))
  ctx.check(r3.ok == false, "stale gen1 retry rejected")
  ctx.assert_eq(r3.code, "generation_conflict", "generation conflict code")
  ctx.assert_eq(r3.save_id, save_id, "conflict result carries save_id")
  ctx.assert_eq(r3.generation, 1, "conflict incoming generation")
  ctx.assert_eq(r3.durable_generation, 2, "conflict durable generation")

  local durable, derr = st:load_chat(save_id)
  ctx.check(durable ~= nil and derr == nil, "durable chat readable after conflict")
  if durable then
    ctx.assert_eq(durable.messages[1].content[1].text, "gen2", "durable content not overwritten by stale save")
    ctx.assert_eq(durable.runtime_state.generation, 2, "durable generation stays 2")
    ctx.assert_eq(durable.updated_at, 200, "durable updated_at stays 200 (rejected save not applied)")
  end

  -- 场景 2：独立会话交错保存（A 的 index 更新窗口内嵌套保存 B）。
  -- 没有 read-modify-write 重读的话，A 的 index 写入会丢 B 的条目。
  local save_a = "20260806_140000_001_000001_interleave_a"
  local save_b = "20260806_150000_001_000001_interleave_b"
  -- updated_at 必须晚于场景 1 的 200，get_last_chat 才指向 B。
  local env_a = make_env(save_a, 1, "A", 300)
  local env_b = make_env(save_b, 1, "B", 400)
  local nested_result = nil
  local nested_ran = false
  st.inject = {
    before_index_update = function(_, sid)
      if sid == save_a and not nested_ran then
        nested_ran = true
        nested_result = st:save(env_b)
      end
    end,
  }
  local ra = st:save(env_a)
  ctx.check(ra.ok == true, "A save ok")
  ctx.check(nested_ran == true, "interleaving hook ran")
  ctx.check(nested_result ~= nil and nested_result.ok == true, "nested B save ok")

  local index = st:get_chats()
  ctx.check(index[save_a] ~= nil, "index contains A")
  ctx.check(index[save_b] ~= nil, "index contains B (no lost update)")
  ctx.assert_eq(index[save_a].message_count, 1, "A entry intact")
  ctx.assert_eq(index[save_b].message_count, 1, "B entry intact")

  local last, lerr = st:get_last_chat()
  ctx.check(last ~= nil and lerr == nil, "get_last_chat ok")
  if last then
    ctx.assert_eq(last.save_id, save_b, "most recent is B")
  end
end)

if not ctx.ok then
  error("concurrent-save failed: " .. table.concat(ctx.failures, "; "), 0)
end
print("HISTORY_OK: concurrent-save")
