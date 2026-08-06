-- filepath: tests/history/trace-dedup.lua
--- history/trace-dedup (H-005): trace lifecycle + natural-turn de-duplication.
--- manual user / assistant reply / error 各记一次（natural turn dedupe_key）；
--- 重复追加返回 duplicate/skipped 且不增加事件行；auto-submit/regenerate 模拟
--- 消息（同内容重放、tag/context/visible=false/tool payload）不算 manual turn；
--- untracked（无 membership）会话零写入（不建 trace 目录、无事件）。

local assert_mod = require("tests.history.lib.assert")
local fixture_project = require("tests.history.lib.fixture_project")
local history = require("maxa.runtime.history")

local ctx = assert_mod.new()

local clock = { t = 1000 }
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

  -- tracked snapshot：start_trace + membership 挂到快照。
  local snapshot = {
    session_id = "sess-trace",
    project_id = "proj-1",
    generation = 1,
    provider_id = "mock",
    protocol = "mock",
    model = "mock-model",
    title = "trace session",
    messages = { text_message("user", "hello"), text_message("assistant", "hi") },
    context_items = {},
    status_snapshot = {},
  }
  local st = service:start_trace(snapshot, { root_trace_id = "trace-root-1" })
  ctx.check(st.ok == true, "start_trace ok")
  if st.ok then
    ctx.assert_eq(st.root_trace_id, "trace-root-1", "start_trace root_trace_id honored")
    ctx.check(type(st.membership) == "table" and st.membership.span_id ~= nil, "start_trace membership present")
    snapshot.trace = { id = st.root_trace_id, membership = st.membership }
  end

  -- 1) manual user turn 记录一次。
  local r1 = service:record_turn(snapshot, snapshot.messages[1], 1)
  ctx.check(r1.appended == true and r1.duplicate == false, "manual user turn recorded once")

  -- 2) 重复追加（同 index/role/content）→ duplicate/skipped，不追加行。
  local r1b = service:record_turn(snapshot, snapshot.messages[1], 1)
  ctx.check(r1b.appended == false and r1b.skipped == true and r1b.duplicate == true, "duplicate turn skipped")
  ctx.check(r1b.event_id ~= nil and r1b.event_id == r1.event_id, "duplicate result carries existing event_id")

  -- 3) assistant reply 记录一次。
  local r2 = service:record_turn(snapshot, snapshot.messages[2], 2)
  ctx.check(r2.appended == true and r2.duplicate == false, "assistant reply recorded")

  -- 4) error turn 记录为 agent_error（与 agent_reply 区分）。
  local err_msg = text_message("assistant", "boom")
  local r3 = service:record_turn(snapshot, err_msg, 3, { error = true, status = "error", reason = "api_failure" })
  ctx.check(r3.appended == true, "error turn recorded")
  if r3.appended then
    ctx.assert_eq(r3.event.kind, "main_turn.agent_error", "error turn kind agent_error")
    ctx.assert_eq(r3.event.status, "error", "error turn status carried")
    ctx.assert_eq(r3.event.reason, "api_failure", "error turn reason carried")
  end

  -- 5) auto-submit/regenerate 模拟消息不记录：
  --    同内容不同 index 也不重复记录（同 role+content 哈希 -> 不同 key，
  --    但此处用带 tag/context/visible=false/tool payload 的消息验证不可见）。
  local tagged = text_message("user", "hello")
  tagged._meta = { tag = "rules" }
  local rt = service:record_turn(snapshot, tagged, 4)
  ctx.check(rt.appended == false and rt.skipped == true, "tagged (rules) message not recorded")

  local context_msg = text_message("user", "hello")
  context_msg.context = { path = "some/file.md" }
  local rc = service:record_turn(snapshot, context_msg, 5)
  ctx.check(rc.appended == false and rc.skipped == true, "context message not recorded")

  local invisible = text_message("user", "hello")
  invisible.opts = { visible = false }
  local ri = service:record_turn(snapshot, invisible, 6)
  ctx.check(ri.appended == false and ri.skipped == true, "visible=false message not recorded")

  local tool_msg = { role = "assistant", content = "tool payload", tools = { calls = { { id = "t1" } } } }
  local rtool = service:record_turn(snapshot, tool_msg, 7)
  ctx.check(rtool.appended == false and rtool.skipped == true, "tool payload message not recorded")

  local fragment_msg = text_message("user", "fragment")
  fragment_msg._meta = { inserted_from_fragment = { source_save_id = "other" } }
  local rfrag = service:record_turn(snapshot, fragment_msg, 8)
  ctx.check(rfrag.appended == false and rfrag.skipped == true, "inserted_from_fragment message not recorded")

  -- 事件文件：恰好 3 行（user/assistant/error），kinds 正确。
  local events = trace.read_events(proj.history_dir, "trace-root-1")
  ctx.check(#events == 3, "exactly 3 events recorded (got " .. tostring(#events) .. ")")
  if #events == 3 then
    ctx.assert_eq(events[1].kind, "main_turn.user_prompt", "event 1 kind user_prompt")
    ctx.assert_eq(events[2].kind, "main_turn.agent_reply", "event 2 kind agent_reply")
    ctx.assert_eq(events[3].kind, "main_turn.agent_error", "event 3 kind agent_error")
    ctx.assert_eq(events[1].message.message_index, 1, "event 1 message_index")
    ctx.assert_eq(events[3].message.message_index, 3, "event 3 message_index")
  end

  -- 6) untracked 会话（无 membership）零写入。
  local untracked = {
    session_id = "sess-untracked",
    project_id = "proj-1",
    generation = 1,
    provider_id = "mock",
    protocol = "mock",
    model = "mock-model",
    messages = { text_message("user", "scratch hello") },
    context_items = {},
    status_snapshot = {},
  }
  local ru = service:record_turn(untracked, untracked.messages[1], 1)
  ctx.check(ru.appended == false and ru.skipped == true, "untracked session records nothing")
  local trace_dirs = vim.fn.glob(proj.history_dir .. "/traces/*", false, true)
  ctx.check(#trace_dirs == 1, "only tracked trace dir exists (got " .. tostring(#trace_dirs) .. ")")
  if #trace_dirs == 1 then
    ctx.check(vim.fn.fnamemodify(trace_dirs[1], ":t") == "trace-root-1", "only trace-root-1 dir present")
  end
end)

if not ctx.ok then
  error("trace-dedup failed: " .. table.concat(ctx.failures, "; "), 0)
end
print("HISTORY_OK: trace-dedup")
