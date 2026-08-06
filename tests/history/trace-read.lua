-- filepath: tests/history/trace-read.lua
--- history/trace-read: read_trace（summary/full + skip/take + parse_errors）、
--- synthesize_trace（无 recorded trace 的 saved chat -> source="synthesized" +
--- gaps）、find_trace_id_for_save_id（direct / chat_meta 路径）、
--- service:trace_read 自动路由。

local assert_mod = require("tests.history.lib.assert")
local fixture_project = require("tests.history.lib.fixture_project")
local history = require("maxa.runtime.history")

local ctx = assert_mod.new()

local clock = { t = 4000 }
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

  -- 构造 recorded trace：6 个 natural turns。
  local snapshot = {
    session_id = "sess-trace-read",
    project_id = "proj-1",
    generation = 1,
    provider_id = "mock",
    protocol = "mock",
    model = "mock-model",
    title = "read session",
    messages = {},
    context_items = {},
    status_snapshot = {},
  }
  local st = service:start_trace(snapshot, { root_trace_id = "trace-read-1" })
  ctx.check(st.ok == true, "start_trace ok")
  if st.ok then
    snapshot.trace = { id = st.root_trace_id, membership = st.membership }
  end
  local turns = {
    text_message("user", "q1"),
    text_message("assistant", "a1"),
    text_message("user", "q2"),
    text_message("assistant", "a2"),
    text_message("user", "q3"),
    text_message("assistant", "a3"),
  }
  for i, msg in ipairs(turns) do
    local r = service:record_turn(snapshot, msg, i)
    ctx.check(r.appended == true, "record turn " .. i)
  end

  -- read_trace summary：skip/take 生效、summary 截断长内容。
  local long_user = text_message("user", string.rep("x", 500))
  local rl = service:record_turn(snapshot, long_user, 7)
  ctx.check(rl.appended == true, "long turn recorded")
  local summary = trace.read_trace(proj.history_dir, "trace-read-1", { mode = "summary", skip = 1, take = 2 })
  ctx.check(summary ~= nil, "read_trace summary ok")
  if summary then
    ctx.assert_eq(summary.source, "recorded", "read_trace source recorded")
    ctx.assert_eq(summary.root_trace_id, "trace-read-1", "read_trace root_trace_id")
    ctx.assert_eq(summary.total_events, 7, "read_trace total_events")
    ctx.assert_eq(summary.returned_events, 2, "read_trace returned_events respects take")
    ctx.assert_eq(summary.skip, 1, "read_trace skip honored")
    ctx.assert_eq(summary.events[1].message.message_index, 2, "read_trace skip respected (first = index 2)")
    ctx.check(type(summary.parse_errors) == "table", "parse_errors empty list present")
  end

  -- full 模式默认 take 200 返回全部。
  local full = trace.read_trace(proj.history_dir, "trace-read-1", { mode = "full" })
  ctx.check(full ~= nil, "read_trace full ok")
  if full then
    ctx.assert_eq(full.returned_events, 7, "full returns all events")
    ctx.check(full.events[7].message.content ~= nil, "full keeps full content")
  end

  -- 长内容 summary 截断。
  local summary_last = trace.read_trace(proj.history_dir, "trace-read-1", { mode = "summary", skip = 6, take = 10 })
  ctx.check(summary_last ~= nil and #(summary_last.events or {}) == 1, "summary last event present")
  if summary_last and summary_last.events[1] then
    ctx.check(#summary_last.events[1].message.content < 500, "summary content truncated")
    ctx.check(summary_last.events[1].message.truncated == true, "summary truncated flag set")
  end

  -- corrupt 事件行 -> parse_errors 收集（不致命）。
  local fh = io.open(proj.history_dir .. "/traces/trace-read-1/events.jsonl", "a")
  fh:write("{corrupt json line\n")
  fh:close()
  local with_err = trace.read_trace(proj.history_dir, "trace-read-1", { mode = "full" })
  ctx.check(with_err ~= nil, "read_trace survives corrupt line")
  if with_err then
    ctx.assert_eq(with_err.total_events, 7, "total_events excludes corrupt line")
    ctx.check(#with_err.parse_errors == 1, "parse_errors has 1 entry")
    if #with_err.parse_errors == 1 then
      ctx.assert_eq(with_err.parse_errors[1].line, 8, "parse_error line number")
    end
  end

  -- synthesize_trace：saved chat 无 trace -> source="synthesized" + gaps。
  local plain = {
    session_id = "sess-plain",
    project_id = "proj-1",
    generation = 1,
    provider_id = "mock",
    protocol = "mock",
    model = "mock-model",
    title = "plain chat",
    messages = { text_message("user", "saved question"), text_message("assistant", "saved answer") },
    context_items = {},
    status_snapshot = {},
  }
  local saved = service:save(plain)
  ctx.check(saved.ok == true, "plain save ok")
  local synth = trace.synthesize_trace(proj.history_dir, saved.save_id, { mode = "summary" })
  ctx.check(synth ~= nil, "synthesize_trace ok")
  if synth then
    ctx.assert_eq(synth.source, "synthesized", "synth source synthesized")
    ctx.assert_eq(synth.root_trace_id, saved.save_id, "synth root_trace_id = save_id")
    ctx.assert_eq(synth.save_id, saved.save_id, "synth save_id")
    ctx.assert_eq(synth.total_events, 2, "synth total_events")
    ctx.assert_eq(synth.returned_events, 2, "synth returned_events")
    ctx.check(#synth.gaps >= 1, "synth gaps present")
    ctx.assert_eq(synth.gaps[1].kind, "unrecorded_runtime_lineage", "synth gap kind")
    ctx.check(synth.events[1].event_id:match("^synth_") ~= nil, "synth event id synthesized")
    ctx.check(synth.events[1].synthesized == true, "synth event synthesized flag")
    ctx.assert_eq(synth.manifest.status, "synthesized", "synth manifest status")
  end

  -- service:trace_read 自动路由。
  local srec = service:trace_read("trace-read-1")
  ctx.check(srec ~= nil and srec.source == "recorded", "service trace_read direct recorded")
  local ssyn = service:trace_read(saved.save_id)
  ctx.check(ssyn ~= nil and ssyn.source == "synthesized", "service trace_read falls back to synthesize")

  -- find_trace_id_for_save_id：direct 路径。
  local direct_id, direct_src = trace.find_trace_id_for_save_id(proj.history_dir, "trace-read-1")
  ctx.assert_eq(direct_id, "trace-read-1", "find direct id")
  ctx.assert_eq(direct_src, "direct", "find direct source")

  -- chat_meta 路径：saved chat 信封 trace.membership 指向另一 root。
  local meta_snapshot = {
    session_id = "sess-meta",
    project_id = "proj-1",
    generation = 1,
    provider_id = "mock",
    protocol = "mock",
    model = "mock-model",
    title = "meta chat",
    messages = { text_message("user", "meta question") },
    context_items = {},
    status_snapshot = {},
    trace = { id = "trace-read-1", membership = { root_trace_id = "trace-read-1", span_id = "span-meta" } },
  }
  local meta_saved = service:save(meta_snapshot)
  ctx.check(meta_saved.ok == true, "meta save ok")
  local meta_id, meta_src = trace.find_trace_id_for_save_id(proj.history_dir, meta_saved.save_id)
  ctx.assert_eq(meta_id, "trace-read-1", "find chat_meta id")
  ctx.assert_eq(meta_src, "chat_meta", "find chat_meta source")
  local smeta = service:trace_read(meta_saved.save_id)
  ctx.check(smeta ~= nil and smeta.source == "recorded" and smeta.resolved_from == "chat_meta", "service trace_read chat_meta route")
end)

if not ctx.ok then
  error("trace-read failed: " .. table.concat(ctx.failures, "; "), 0)
end
print("HISTORY_OK: trace-read")
