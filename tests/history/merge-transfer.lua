-- filepath: tests/history/merge-transfer.lua
--- history/merge-transfer: merge 精确范围/顺序/provenance（每条插入消息带
--- source_save_id + range）、源 close 行为显式；transfer copy/move 到第二
--- fixture 项目根（.maxa/ 标记）：目标带 transfer provenance + 新 save_id、
--- 源完好；move 目标提交后才删除源文件与 index 条目。

local assert_mod = require("tests.history.lib.assert")
local fixture_project = require("tests.history.lib.fixture_project")
local history = require("maxa.runtime.history")

local ctx = assert_mod.new()

local clock = { t = 3000 }
local function now()
  clock.t = clock.t + 1
  return clock.t
end

local function text_message(role, text)
  return { role = role, content = { { type = "text", text = text } } }
end

local function make_snapshot(session_id, messages, gen)
  return {
    session_id = session_id,
    project_id = "proj-1",
    generation = gen or 1,
    provider_id = "mock",
    protocol = "mock",
    model = "mock-model",
    title = nil,
    messages = messages,
    context_items = {},
    usage = {},
    status_snapshot = {},
    trace = { id = nil, membership = {} },
  }
end

fixture_project.with_project(function(proj)
  local service = history.new({ root = proj.root, clock = now })

  -- 源 A（3 条）与源 B（2 条）。
  local sa = service:save(make_snapshot("sess-a", {
    text_message("user", "src-a1"),
    text_message("assistant", "src-a2"),
    text_message("user", "src-a3"),
  }))
  local sb = service:save(make_snapshot("sess-b", {
    text_message("user", "src-b1"),
    text_message("assistant", "src-b2"),
  }))
  ctx.check(sa.ok and sb.ok, "source saves ok")

  -- merge：目标 1 条 + A[2..3] + B[1..1] -> 顺序 u0,a2,a3,b1；provenance 附加。
  local target = make_snapshot("sess-t", { text_message("user", "target-0") })
  local m = service:merge(target, {
    { save_id = sa.save_id, start_index = 2, end_index = 3 },
    { save_id = sb.save_id, start_index = 1, end_index = 1 },
  })
  ctx.check(m.ok == true, "merge ok")
  ctx.check(m.closed == true, "close_source default true")
  ctx.check(m.target_save_id ~= nil, "merge target_save_id present")

  local bundle, berr = service:open(m.target_save_id)
  ctx.check(bundle ~= nil and berr == nil, "merged bundle readable")
  if bundle then
    ctx.assert_eq(#bundle.messages, 4, "merged message count (1 target + 2 + 1)")
    ctx.assert_eq(bundle.messages[1].content[1].text, "target-0", "target message first")
    ctx.assert_eq(bundle.messages[2].content[1].text, "src-a2", "source A range first")
    ctx.assert_eq(bundle.messages[3].content[1].text, "src-a3", "source A range second")
    ctx.assert_eq(bundle.messages[4].content[1].text, "src-b1", "source B range after A")
    -- 插入消息 provenance：source_save_id + range。
    local prov = bundle.messages[2].provenance
    ctx.check(type(prov) == "table" and #prov > 0, "provenance attached to inserted message")
    if type(prov) == "table" and #prov > 0 then
      local rec = prov[#prov]
      ctx.assert_eq(rec.source_save_id, sa.save_id, "provenance source_save_id")
      ctx.assert_eq(rec.range[1], 2, "provenance range start")
      ctx.assert_eq(rec.range[2], 3, "provenance range end")
    end
    -- 目标自身消息不附加 merge provenance。
    local own_prov = bundle.messages[1].provenance
    ctx.check(own_prov == nil or (type(own_prov) == "table" and #own_prov == 0),
      "target original message has no merge provenance")
  end

  -- 范围校验：越界/反向/缺失源。
  local bad1 = service:merge(target, { { save_id = sa.save_id, start_index = 0, end_index = 1 } })
  ctx.check(bad1.ok == false and bad1.code == "invalid_merge", "merge out-of-bounds rejected")
  local bad2 = service:merge(target, { { save_id = sa.save_id, start_index = 2, end_index = 99 } })
  ctx.check(bad2.ok == false and bad2.code == "invalid_merge", "merge overflow rejected")
  local bad3 = service:merge(target, { { save_id = "no-such-id", start_index = 1, end_index = 1 } })
  ctx.check(bad3.ok == false and bad3.code == "not_found", "merge missing source rejected")
  local bad4 = service:merge(target, { { save_id = sa.save_id, start_index = 3, end_index = 2 } })
  ctx.check(bad4.ok == false and bad4.code == "invalid_merge", "merge reversed range rejected")

  -- close_source=false 显式关闭行为。
  local m2 = service:merge(make_snapshot("sess-t2", {}), { { save_id = sb.save_id, start_index = 1, end_index = 2 } }, {
    close_source = false,
  })
  ctx.check(m2.ok == true, "merge ok with close_source=false")
  ctx.check(m2.closed == false, "close_source false honored")

  -- transfer copy：目标项目根（fixture 第二项目，带 .maxa/ 标记）。
  local target_proj = fixture_project.make_fixture_project()
  local tr = service:transfer(sa.save_id, target_proj.root, { mode = "copy" })
  ctx.check(tr.ok == true, "transfer copy ok")
  ctx.check(tr.source_deleted == false, "copy keeps source")
  ctx.check(tr.target_save_id ~= sa.save_id, "transfer generates new save_id")
  ctx.assert_eq(tr.target_history_dir, target_proj.history_dir, "target history dir")

  -- 源完好。
  local src_after, _ = service:open(sa.save_id)
  ctx.check(src_after ~= nil, "source intact after copy")

  -- 目标可读 + transfer provenance + cwd/project_root 更新。
  local target_storage = history.storage.new({ root = target_proj.root })
  local tenv, terr = target_storage:load_chat(tr.target_save_id)
  ctx.check(tenv ~= nil and terr == nil, "target chat readable")
  if tenv then
    ctx.check(tenv.runtime_state.transfer ~= nil, "target has transfer provenance")
    if tenv.runtime_state.transfer then
      ctx.assert_eq(tenv.runtime_state.transfer.mode, "copy", "transfer mode copy")
      ctx.assert_eq(tenv.runtime_state.transfer.source_project_root, proj.root, "transfer source_project_root")
      ctx.assert_eq(tenv.runtime_state.transfer.source_history_dir, proj.history_dir, "transfer source_history_dir")
      ctx.assert_eq(tenv.runtime_state.transfer.source_save_id, sa.save_id, "transfer source_save_id")
      ctx.check(type(tenv.runtime_state.transfer.transferred_at) == "number", "transferred_at number")
    end
    ctx.assert_eq(tenv.runtime_state.cwd, target_proj.root, "target cwd updated")
    ctx.assert_eq(tenv.runtime_state.project_root, target_proj.root, "target project_root updated")
    ctx.assert_eq(#tenv.messages, 3, "target messages copied")
  end

  -- transfer title override。
  local tr2 = service:transfer(sb.save_id, target_proj.root, { mode = "copy", title = "Transferred Title" })
  ctx.check(tr2.ok == true, "transfer with title ok")
  local tenv2, _ = target_storage:load_chat(tr2.target_save_id)
  ctx.check(tenv2 ~= nil, "second target chat readable")
  if tenv2 then
    ctx.assert_eq(tenv2.title, "Transferred Title", "transfer title override")
  end

  -- transfer move：目标提交后源文件 + index 条目删除。
  local tr3 = service:transfer(sb.save_id, target_proj.root, { mode = "move" })
  ctx.check(tr3.ok == true, "transfer move ok")
  ctx.check(tr3.source_deleted == true, "move deletes source")
  local gone, gerr = service:open(sb.save_id)
  ctx.check(gone == nil, "source gone after move")
  ctx.check(gerr ~= nil and gerr.cause and gerr.cause.history_code == "not_found", "source missing typed not_found")
  ctx.check(service:list()[sb.save_id] == nil, "source index entry removed")
  ctx.check(service:list()[sa.save_id] ~= nil, "unmoved source intact in index")
  ctx.check(vim.fn.filereadable(target_proj.history_dir .. "/chats/" .. tr3.target_save_id .. ".json") == 1,
    "moved target file exists")

  target_proj.cleanup()
end)

if not ctx.ok then
  error("merge-transfer failed: " .. table.concat(ctx.failures, "; "), 0)
end
print("HISTORY_OK: merge-transfer")
