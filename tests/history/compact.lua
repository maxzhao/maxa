-- filepath: tests/history/compact.lua
--- history/compact (H-004): compaction service + trace archive consistency.
---   * protected prefix（前 N 个可见 user 轮次）逐字保留、绝不归档/移除；
---   * 归档范围在 trace 中持久化（archive JSON + compression.archive_created 恰一次；
---     同范围重复 apply 经 dedupe_key 不追加任何内容）；
---   * 替换消息 = protected + compact_summary 摘要消息（tag 在 IGNORED_TAGS 内，
---     不构成 natural turn）；overwrite 尾部（range 之后）保留；
---   * overwrite 保持 save_id（generation+1）；new 生成 `compact_` 前缀 save_id +
---     compression provenance meta {compressed_from, compressed_at, previous}；
---   * 恢复一致：restore_bundle 返回 protected+summary；trace_read(include_archives)
---     可读归档；错误路径（protected 重叠/非法范围/非法模式/无可压缩/LLM 失败）
---     零持久化。

local assert_mod = require("tests.history.lib.assert")
local fixture_project = require("tests.history.lib.fixture_project")
local history = require("maxa.runtime.history")
local events = require("maxa.runtime.events")

local ctx = assert_mod.new()

local clock = { t = 6000 }
local function now()
  clock.t = clock.t + 1
  return clock.t
end

local function text_message(role, text, meta)
  local m = { role = role, content = { { type = "text", text = text } } }
  if meta then
    m._meta = meta
  end
  return m
end

local function snapshot(session_id, messages, extra)
  local s = {
    session_id = session_id,
    project_id = "proj-1",
    generation = 1,
    provider_id = "mock",
    protocol = "mock",
    model = "mock-model",
    title = "compact chat",
    messages = messages,
    context_items = {},
    status_snapshot = {},
    runtime_state = { compact_protected_prefix_count = 1 },
  }
  for k, v in pairs(extra or {}) do
    s[k] = v
  end
  return s
end

fixture_project.with_project(function(proj)
  local compacted_events = {}
  local saved_events = {}
  local bus = events.new()
  bus.on("history.compacted", function(payload)
    compacted_events[#compacted_events + 1] = payload
  end)
  bus.on("history.saved", function(payload)
    saved_events[#saved_events + 1] = payload
  end)
  local provider = { text = "SUMMARY", fail = false, calls = 0, last_prompt = nil }
  provider.request = function(prompt, cb)
    provider.calls = provider.calls + 1
    provider.last_prompt = prompt
    if provider.fail then
      cb(nil, "provider exploded")
      return
    end
    cb(provider.text, nil)
  end
  local service = history.new({
    root = proj.root,
    clock = now,
    events = bus,
    provider_resolver = function()
      return provider
    end,
  })
  local trace = history.trace

  -- ============ 1) overwrite：protected 保留 + 归档 trace + 恢复一致 ============
  do
    local messages = {
      text_message("user", "protect me"),
      text_message("assistant", "protected reply"),
      text_message("user", "q2"),
      text_message("assistant", "a2"),
      text_message("user", "q3", { tag = "rules" }), -- 不可见：归档 turns 排除
      text_message("assistant", "a3"),
      text_message("user", "q4"),
      text_message("assistant", "a4"),
    }
    local snap = snapshot("sess-compact", messages)
    local st = service:start_trace(snap, { root_trace_id = "trace-compact-1" })
    ctx.check(st.ok == true, "start_trace ok")
    snap.trace = { id = st.root_trace_id, membership = st.membership }
    local sv = service:save(snap)
    ctx.check(sv.ok == true, "seed save ok")
    local seed_save_id = sv.save_id

    provider.text = "COMPACT SUMMARY OVERWRITE"
    local cr = service:compact(snap, { mode = "overwrite" })
    ctx.check(cr.ok == true, "overwrite compact ok")
    if cr.ok then
      ctx.assert_eq(cr.action, "overwrite", "action overwrite")
      ctx.assert_eq(cr.save_id, seed_save_id, "overwrite keeps save_id")
      ctx.assert_eq(cr.generation, 2, "generation+1")
      ctx.assert_eq(cr.truncated_count, 7, "truncated_count = 7 (range 2..8)")
      ctx.check(cr.archived.tracked == true, "archive tracked")
      ctx.check(cr.archived.appended == true, "archive event appended")
    end
    ctx.check(#saved_events >= 2, "history.saved emitted for seed + compact save")

    -- archive JSON 落盘（traces/<id>/archives/）
    local archive_files = vim.fn.glob(proj.history_dir .. "/traces/trace-compact-1/archives/*.json", false, true)
    ctx.check(#archive_files == 1, "one archive JSON (got " .. tostring(#archive_files) .. ")")

    -- trace 事件：compression.archive_created 恰一次 + compression.applied 恰一次
    local events_list = trace.read_events(proj.history_dir, "trace-compact-1")
    local archive_created = 0
    local applied = 0
    for _, ev in ipairs(events_list) do
      if ev.kind == "compression.archive_created" then
        archive_created = archive_created + 1
      elseif ev.kind == "compression.applied" then
        applied = applied + 1
      end
    end
    ctx.assert_eq(archive_created, 1, "compression.archive_created once")
    ctx.assert_eq(applied, 1, "compression.applied once")

    -- 替换消息：protected(1) + compact_summary(1)
    local env = service:open(cr.save_id)
    ctx.check(env ~= nil, "compacted chat readable")
    if env then
      ctx.assert_eq(#env.messages, 2, "replacement = protected + summary")
      ctx.assert_same_table(env.messages[1], messages[1], "protected message verbatim")
      ctx.check(
        env.messages[2]._meta ~= nil and env.messages[2]._meta.tag == "compact_summary",
        "summary message has compact_summary tag"
      )
      ctx.assert_eq(env.messages[2].content[1].text, "COMPACT SUMMARY OVERWRITE", "summary text persisted")
      ctx.assert_eq(env.runtime_state.generation, 2, "durable generation 2")
      ctx.assert_eq(env.runtime_state.compact_protected_prefix_count, 1, "protected count preserved")
      ctx.check(env.runtime_state.compression_provenance ~= nil, "compression provenance present")
      if env.runtime_state.compression_provenance then
        ctx.assert_eq(
          env.runtime_state.compression_provenance.compressed_from,
          seed_save_id,
          "provenance compressed_from = original save_id"
        )
        ctx.check(type(env.runtime_state.compression_provenance.compressed_at) == "number", "provenance compressed_at number")
        ctx.assert_eq(env.runtime_state.compression_provenance.previous, nil, "provenance previous nil (first compact)")
      end
      -- envelope.opts 镜像（legacy compat）
      local durable = service.storage:load_chat(cr.save_id)
      ctx.check(
        durable ~= nil and durable.opts ~= nil and durable.opts.compact_protected_prefix_count == 1,
        "envelope.opts mirror written"
      )
    end

    -- 恢复一致：restore_bundle 返回 protected + summary；trace_read 可读归档
    local bundle = service:restore_bundle(cr.save_id)
    ctx.check(bundle ~= nil, "restore_bundle ok")
    if bundle then
      ctx.assert_eq(#bundle.messages, 2, "bundle messages = protected + summary")
      ctx.assert_same_table(bundle.messages[1], messages[1], "bundle protected verbatim")
      ctx.assert_eq(bundle.messages[2]._meta.tag, "compact_summary", "bundle summary tag")
    end
    local tr = service:trace_read("trace-compact-1", { include_archives = true, mode = "full" })
    ctx.check(tr ~= nil, "trace_read ok")
    if tr then
      ctx.check(#(tr.archives or {}) == 1, "trace_read include_archives returns 1 archive")
      if tr.archives and tr.archives[1] then
        ctx.assert_eq(tr.archives[1].range.start_index, 2, "archive range start 2")
        ctx.assert_eq(tr.archives[1].range.end_index, 8, "archive range end 8")
        ctx.assert_eq(#(tr.archives[1].turns or {}), 6, "archive turns = 6 visible turns")
        ctx.assert_eq(tr.archives[1].counts.turn_count, 6, "archive counts.turn_count")
        ctx.assert_eq(tr.archives[1].counts.omitted_count, 1, "archive counts.omitted (rules tag)")
        ctx.assert_eq(tr.archives[1].source_save_id, seed_save_id, "archive source_save_id")
      end
    end

    -- 重复 apply 同范围：dedupe 命中，不追加任何内容
    local dup = trace.archive_compression_range(
      proj.history_dir,
      "trace-compact-1",
      {
        messages = messages,
        save_id = seed_save_id,
        source_type = "saved",
        trace = { id = "trace-compact-1", membership = snap.trace.membership },
      },
      { start_index = 2, end_index = 8 },
      { tool_name = "compact", mode = "overwrite" }
    )
    ctx.check(dup ~= nil, "duplicate archive call returns result")
    if dup then
      ctx.check(dup.duplicate == true and dup.appended == false, "duplicate archive appends nothing")
    end
    local events_after = trace.read_events(proj.history_dir, "trace-compact-1")
    local created_after = 0
    for _, ev in ipairs(events_after) do
      if ev.kind == "compression.archive_created" then
        created_after = created_after + 1
      end
    end
    ctx.assert_eq(created_after, 1, "archive_created still once after duplicate")

    -- history.compacted 事件
    ctx.check(#compacted_events >= 1, "history.compacted emitted")
    if compacted_events[1] then
      ctx.assert_eq(compacted_events[1].action, "overwrite", "compacted event action")
      ctx.assert_eq(compacted_events[1].save_id, seed_save_id, "compacted event save_id")
    end
  end

  -- ============ 2) new：compact_ 前缀 save_id + provenance meta，原会话不变 ============
  do
    local messages = {
      text_message("user", "n1"),
      text_message("assistant", "na1"),
      text_message("user", "n2"),
      text_message("assistant", "na2"),
    }
    local snap = snapshot("sess-compact-new", messages)
    local st = service:start_trace(snap, { root_trace_id = "trace-compact-2" })
    ctx.check(st.ok == true, "new-mode start_trace ok")
    snap.trace = { id = st.root_trace_id, membership = st.membership }
    local sv = service:save(snap)
    ctx.check(sv.ok == true, "new-mode seed save ok")
    local seed_save_id = sv.save_id

    provider.text = "NEW SUMMARY"
    local cn = service:compact(snap, { mode = "new" })
    ctx.check(cn.ok == true, "new-mode compact ok")
    if cn.ok then
      ctx.assert_eq(cn.action, "new", "action new")
      ctx.check(cn.save_id:match("^compact_") ~= nil, "new save_id has compact_ prefix (got " .. tostring(cn.save_id) .. ")")
      ctx.assert_eq(cn.generation, 2, "new generation+1")
    end
    -- 绑定切换到新会话
    ctx.check(service:current_save_id("sess-compact-new") == cn.save_id, "session bound to compact save_id")
    local envn = service:open(cn.save_id)
    ctx.check(envn ~= nil, "new compacted chat readable")
    if envn then
      ctx.assert_eq(#envn.messages, 2, "new replacement = protected + summary (no tail)")
      ctx.assert_eq(envn.messages[2]._meta.tag, "compact_summary", "new summary tag")
      ctx.assert_eq(envn.messages[2].content[1].text, "NEW SUMMARY", "new summary text")
      ctx.check(envn.runtime_state.compression_provenance ~= nil, "new provenance present")
      if envn.runtime_state.compression_provenance then
        ctx.assert_eq(
          envn.runtime_state.compression_provenance.compressed_from,
          seed_save_id,
          "new provenance compressed_from = original"
        )
        ctx.check(type(envn.runtime_state.compression_provenance.compressed_at) == "number", "new provenance compressed_at number")
        ctx.assert_eq(envn.runtime_state.compression_provenance.previous, nil, "new provenance previous nil")
      end
    end
    -- 原会话保持不动（new 模式不修改原 durable 会话）
    local orig = service:open(seed_save_id)
    ctx.check(orig ~= nil, "original session readable")
    if orig then
      ctx.assert_eq(#orig.messages, 4, "original session untouched (4 messages)")
      ctx.assert_eq(orig.runtime_state.generation, 1, "original generation unchanged")
    end
    -- 归档范围 2..4：3 个可见 turns
    local tr2 = service:trace_read("trace-compact-2", { include_archives = true, mode = "full" })
    ctx.check(tr2 ~= nil and #(tr2.archives or {}) == 1, "new-mode archive recorded")
    if tr2 and tr2.archives and tr2.archives[1] then
      ctx.assert_eq(tr2.archives[1].range.end_index, 4, "new-mode archive range end 4")
      ctx.assert_eq(#(tr2.archives[1].turns or {}), 3, "new-mode archive 3 turns")
    end
  end

  -- ============ 3) 显式范围 + 预计算摘要 + 错误路径 ============
  do
    local messages = {
      text_message("user", "e1"),
      text_message("assistant", "ea1"),
      text_message("user", "e2"),
      text_message("assistant", "ea2"),
      text_message("user", "e3"),
    }
    local snap = snapshot("sess-explicit", messages)
    local st = service:start_trace(snap, { root_trace_id = "trace-compact-3" })
    ctx.check(st.ok == true, "explicit start_trace ok")
    snap.trace = { id = st.root_trace_id, membership = st.membership }
    local sv = service:save(snap)
    ctx.check(sv.ok == true, "explicit seed save ok")
    local seed_save_id = sv.save_id

    -- 预计算摘要：provider 不被调用；显式范围 {3,4}；overwrite 尾部（index 5）保留。
    provider.calls = 0
    provider.last_prompt = nil
    local cs = service:compact(snap, {
      mode = "overwrite",
      summary = "PRECOMPUTED SUMMARY",
      range = { start_index = 3, end_index = 4 },
    })
    ctx.check(cs.ok == true, "explicit range compact ok")
    if cs.ok then
      ctx.assert_eq(cs.save_id, seed_save_id, "explicit keeps save_id")
      ctx.assert_eq(cs.truncated_count, 2, "explicit truncated_count 2")
      ctx.assert_eq(provider.calls, 0, "precomputed summary skips provider")
      ctx.assert_eq(provider.last_prompt, nil, "precomputed summary no prompt")
    end
    local enve = service:open(seed_save_id)
    ctx.check(enve ~= nil, "explicit compacted readable")
    if enve then
      ctx.assert_eq(#enve.messages, 3, "explicit replacement = protected + summary + tail")
      ctx.assert_same_table(enve.messages[1], messages[1], "explicit protected verbatim")
      ctx.assert_eq(enve.messages[2].content[1].text, "PRECOMPUTED SUMMARY", "explicit summary text")
      ctx.assert_same_table(enve.messages[3], messages[5], "explicit tail after range preserved")
      ctx.assert_eq(enve.runtime_state.generation, 2, "explicit generation+1")
    end
    local tr3 = service:trace_read("trace-compact-3", { include_archives = true, mode = "full" })
    if tr3 and tr3.archives and tr3.archives[1] then
      ctx.assert_eq(tr3.archives[1].range.start_index, 3, "explicit archive start 3")
      ctx.assert_eq(tr3.archives[1].range.end_index, 4, "explicit archive end 4")
      ctx.assert_eq(#(tr3.archives[1].turns or {}), 2, "explicit archive 2 turns")
    else
      ctx.check(false, "explicit archive recorded")
    end

    -- 错误路径：protected 重叠 / 非法范围 / 非法模式 / 无可压缩 / LLM 失败 —— 零持久化。
    local index_before = vim.tbl_count(service:list())
    local archive_files_before = vim.fn.glob(proj.history_dir .. "/traces/trace-compact-3/archives/*.json", false, true)
    local overlap = service:compact(snap, { mode = "overwrite", range = { start_index = 1, end_index = 4 } })
    ctx.check(overlap.ok == false and overlap.code == "protected_prefix_overlap", "protected overlap rejected")
    local bad_range = service:compact(snap, { mode = "overwrite", range = { start_index = 3, end_index = 99 } })
    ctx.check(bad_range.ok == false and bad_range.code == "invalid_range", "invalid range rejected")
    local bad_mode = service:compact(snap, { mode = "bogus" })
    ctx.check(bad_mode.ok == false and bad_mode.code == "invalid_mode", "invalid mode rejected")
    local full_snap = vim.deepcopy(snap)
    full_snap.runtime_state = vim.deepcopy(full_snap.runtime_state or {})
    full_snap.runtime_state.compact_protected_prefix_count = 5
    local nothing = service:compact(full_snap, { mode = "overwrite" })
    ctx.check(nothing.ok == false and nothing.code == "nothing_to_compact", "nothing to compact rejected")
    provider.fail = true
    local failed = service:compact(snap, { mode = "overwrite" })
    ctx.check(failed.ok == false and failed.code == "summary_failed", "summary failure returns summary_failed")
    provider.fail = false
    ctx.assert_eq(vim.tbl_count(service:list()), index_before, "error paths persist nothing (index unchanged)")
    local archive_files_after = vim.fn.glob(proj.history_dir .. "/traces/trace-compact-3/archives/*.json", false, true)
    ctx.assert_eq(#archive_files_after, #archive_files_before, "error paths persist nothing (no new archives)")
  end
end)

if not ctx.ok then
  error("compact failed: " .. table.concat(ctx.failures, "; "), 0)
end
print("HISTORY_OK: compact")
