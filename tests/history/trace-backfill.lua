-- filepath: tests/history/trace-backfill.lua
--- history/trace-backfill: backfill 幂等回填。
--- 混合消息：可见 user/assistant turns 追加；tool/tagged/context 消息跳过；
--- summary `trace.backfilled` 事件追加一次；第二次 backfill 通过 dedupe 零新增。

local assert_mod = require("tests.history.lib.assert")
local fixture_project = require("tests.history.lib.fixture_project")
local history = require("maxa.runtime.history")

local ctx = assert_mod.new()

local clock = { t = 2000 }
local function now()
  clock.t = clock.t + 1
  return clock.t
end

fixture_project.with_project(function(proj)
  local service = history.new({ root = proj.root, clock = now })
  local trace = history.trace

  local function text_message(role, text)
    return { role = role, content = { { type = "text", text = text } } }
  end

  local messages = {
    text_message("user", "question 1"),
    text_message("assistant", "answer 1"),
    { role = "user", content = "tool call", tools = { calls = { { id = "t1" } } } },
    { role = "assistant", content = "tagged", _meta = { tag = "mcp_tools" } },
    text_message("user", "question 2"),
    text_message("assistant", "answer 2"),
  }

  local snapshot = {
    session_id = "sess-backfill",
    project_id = "proj-1",
    generation = 1,
    provider_id = "mock",
    protocol = "mock",
    model = "mock-model",
    title = "backfill session",
    messages = messages,
    context_items = {},
    status_snapshot = {},
  }

  -- trace start + membership 挂快照（root_trace_id 显式）。
  local st = service:start_trace(snapshot, { root_trace_id = "trace-bf" })
  ctx.check(st.ok == true, "start_trace ok")
  if st.ok then
    snapshot.trace = { id = st.root_trace_id, membership = st.membership }
  end

  -- 保存信封（trace.membership 随信封持久化）。
  local saved = service:save(snapshot)
  ctx.check(saved.ok == true, "envelope save ok")
  if saved.ok then
    local env, _ = service:open(saved.save_id)
    ctx.check(env ~= nil, "saved envelope readable")
    if env then
      ctx.assert_eq(env.trace.id, "trace-bf", "envelope trace.id persisted")
      ctx.check(type(env.trace.membership) == "table" and env.trace.membership.root_trace_id == "trace-bf", "envelope trace.membership persisted")
    end
  end

  -- 第一次 backfill：4 个可见 turn + 1 个 summary。
  local result = service:backfill(snapshot)
  ctx.check(#result.errors == 0, "backfill no errors")
  ctx.assert_eq(result.added, 4, "backfill added 4 visible turns")
  ctx.assert_eq(result.total_candidates, 4, "backfill total_candidates 4")
  ctx.assert_eq(result.skipped, 0, "backfill skipped 0 turn events")
  ctx.check(result.backfill_event_added == true, "backfill summary event appended once")

  -- 事件文件：4 turns + 1 summary = 5 行。
  local events = trace.read_events(proj.history_dir, "trace-bf")
  ctx.check(#events == 5, "5 events after first backfill (got " .. tostring(#events) .. ")")
  if #events == 5 then
    ctx.assert_eq(events[5].kind, "trace.backfilled", "summary event last")
    local kinds = {}
    for _, e in ipairs(events) do
      kinds[#kinds + 1] = e.kind
    end
    local unexpected = {}
    for _, k in ipairs(kinds) do
      if k ~= "main_turn.user_prompt" and k ~= "main_turn.agent_reply" and k ~= "trace.backfilled" then
        unexpected[#unexpected + 1] = k
      end
    end
    ctx.check(#unexpected == 0, "no tool/tagged/context events recorded (got " .. vim.inspect(unexpected) .. ")")
  end

  -- 第二次 backfill：幂等，零新增。
  local second = service:backfill(snapshot)
  ctx.check(#second.errors == 0, "second backfill no errors")
  ctx.assert_eq(second.added, 0, "second backfill adds nothing")
  ctx.assert_eq(second.total_candidates, 4, "second backfill re-evaluates same candidates")
  ctx.assert_eq(second.skipped, 4, "second backfill skips all existing turns")
  ctx.check(second.backfill_event_skipped == true, "second backfill summary deduped")

  local events2 = trace.read_events(proj.history_dir, "trace-bf")
  ctx.check(#events2 == 5, "event count unchanged after second backfill (got " .. tostring(#events2) .. ")")

  -- index 反映最终状态。
  local index = trace.read_index(proj.history_dir, "trace-bf")
  ctx.check(index ~= nil, "index readable")
  if index then
    ctx.assert_eq(index.event_count, 5, "index event_count 5")
    ctx.check(type(index.dedupe_keys) == "table" and next(index.dedupe_keys) ~= nil, "index dedupe_keys populated")
  end
end)

if not ctx.ok then
  error("trace-backfill failed: " .. table.concat(ctx.failures, "; "), 0)
end
print("HISTORY_OK: trace-backfill")
