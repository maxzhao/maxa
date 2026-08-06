-- filepath: tests/history/create-save-open.lua
--- H-001 storage create-save-open: stable identity, atomic session/index write,
--- load_chat returns identical normalized messages, index entry metadata,
--- get_last_chat ordering. Fixture project root has .maxa/ marker; development
--- .supermax/ is absent.

local assert_mod = require("tests.history.lib.assert")
local fixture_project = require("tests.history.lib.fixture_project")
local history = require("maxa.runtime.history")

local ctx = assert_mod.new()

fixture_project.with_project(function(proj)
  local st = history.storage.new({ root = proj.root })

  local messages = {
    { role = "user", content = { { type = "text", text = "hello world" } } },
    { role = "assistant", content = { { type = "text", text = "hi there" } } },
  }

  local function make_env(save_id, session_id, updated_at, model)
    return {
      schema_version = 1,
      session_id = session_id,
      save_id = save_id,
      project_id = "proj-1",
      parent_session_id = nil,
      created_at = 1,
      updated_at = updated_at,
      title = nil,
      provider_id = "mock",
      protocol = "mock",
      model = model,
      messages = messages,
      context_items = {},
      runtime_state = { generation = 1, cwd = proj.root, project_root = proj.root },
      trace = { id = nil, membership = {} },
      status_snapshot = {},
    }
  end

  local save_id = "20260806_120000_001_000001_abcdef"
  local res = st:save(make_env(save_id, "sess-1", 10, "mock-model"))
  ctx.check(res.ok == true, "save ok")
  ctx.assert_eq(res.status, "saved", "save status")
  ctx.assert_eq(res.save_id, save_id, "save_id echoed")

  -- 原子写产物：会话文件 + index 文件存在，无临时残留。
  ctx.check(vim.fn.filereadable(proj.history_dir .. "/chats/" .. save_id .. ".json") == 1, "chat file exists")
  ctx.check(vim.fn.filereadable(proj.history_dir .. "/index.json") == 1, "index file exists")
  local leftovers = vim.fn.glob(proj.history_dir .. "/chats/*.tmp*", false, true)
  ctx.check(#leftovers == 0, "no temp leftovers after atomic write")

  -- load_chat 返回归一消息一致（不透明数组按原样持久化）。
  local env, err = st:load_chat(save_id)
  ctx.check(env ~= nil and err == nil, "load_chat returns envelope")
  if env then
    ctx.assert_same_table(env.messages, messages, "messages round-trip identical")
    ctx.assert_eq(env.save_id, save_id, "stable save_id")
    ctx.assert_eq(env.session_id, "sess-1", "stable session_id")
    ctx.assert_eq(env.schema_version, 1, "schema_version 1")
  end

  -- index 条目字段。
  local index = st:get_chats()
  local entry = index[save_id]
  ctx.check(entry ~= nil, "index entry present")
  if entry then
    ctx.assert_eq(entry.message_count, 2, "message_count")
    ctx.assert_eq(entry.token_estimate, math.floor(19 / 4), "token_estimate floor(chars/4)")
    ctx.assert_eq(entry.model, "mock-model", "entry model")
    ctx.assert_eq(entry.provider_id, "mock", "entry provider_id")
    ctx.assert_eq(entry.protocol, "mock", "entry protocol")
    ctx.assert_eq(entry.session_id, "sess-1", "entry session_id")
    ctx.assert_eq(entry.parent_session_id, nil, "entry parent_session_id nil")
    ctx.assert_eq(entry.compact_protected_prefix_count, 0, "entry compact count default 0")
    ctx.assert_eq(entry.cwd, proj.root, "entry cwd")
    ctx.assert_eq(entry.project_root, proj.root, "entry project_root")
  end

  -- 第二个更晚的会话：get_last_chat 返回它；filter_fn 生效。
  local save_id2 = "20260806_130000_001_000001_ghijkl"
  local res2 = st:save(make_env(save_id2, "sess-2", 20, "mock-model"))
  ctx.check(res2.ok == true, "second save ok")

  local last, lerr = st:get_last_chat()
  ctx.check(last ~= nil and lerr == nil, "get_last_chat returns envelope")
  if last then
    ctx.assert_eq(last.save_id, save_id2, "get_last_chat most recent")
  end

  local filtered = st:get_chats(function(entry)
    return entry.model == "mock-model"
  end)
  ctx.check(filtered[save_id] ~= nil and filtered[save_id2] ~= nil, "filter_fn keeps both")
  local none = st:get_chats(function(entry)
    return entry.model == "nope"
  end)
  ctx.check(vim.tbl_isempty(none), "filter_fn excludes others")

  -- 缺失会话：nil + 无错误。
  local missing, merr = st:load_chat("20260101_000000_001_000001_missing")
  ctx.check(missing == nil and merr == nil, "missing chat returns nil without error")

  -- 稳定身份：同一 save_id 重复加载一致。
  local env_again = st:load_chat(save_id)
  ctx.assert_eq(env_again.save_id, save_id, "stable identity across loads")
end)

-- W2 扩展：服务层 restore bundle 往返（open -> stack_from_table -> to_table 一致、
-- runtime_state 保留）——这是后续 host wave 重建会话所需的最小恢复束。
fixture_project.with_project(function(proj)
  local service = history.new({ root = proj.root })
  local conv = require("maxa.runtime.conversation")

  local stack = conv.new_stack()
  stack:add_message({ role = "user", content = { { type = "text", text = "svc hello" } } })
  stack:add_message({ role = "assistant", content = { { type = "text", text = "svc hi" } } })
  local msgs = stack:to_table()

  local snapshot = {
    session_id = "sess-svc-1",
    project_id = "proj-1",
    generation = 2,
    provider_id = "mock",
    protocol = "mock",
    model = "mock-model",
    title = "Service Chat",
    messages = msgs,
    context_items = { { id = "ctx-9" } },
    usage = { total_tokens = 42 },
    status_snapshot = { state = "waiting_for_user" },
    trace = { id = nil, membership = {} },
    runtime_state = { cwd = proj.root, project_root = proj.root, compact_protected_prefix_count = 1 },
  }

  local sv = service:save(snapshot)
  ctx.check(sv.ok == true, "service save ok")
  ctx.assert_eq(sv.status, "saved", "service save status")
  ctx.check(service:current_save_id("sess-svc-1") == sv.save_id, "service bound save_id")

  local bundle, berr = service:open(sv.save_id)
  ctx.check(bundle ~= nil and berr == nil, "service open returns bundle")
  if bundle then
    ctx.assert_eq(bundle.save_id, sv.save_id, "bundle save_id")
    ctx.assert_eq(bundle.title, "Service Chat", "bundle title")
    ctx.assert_eq(bundle.provider_id, "mock", "bundle provider_id")
    ctx.assert_eq(bundle.protocol, "mock", "bundle protocol")
    ctx.assert_eq(bundle.model, "mock-model", "bundle model")
    -- 消息经 stack_from_table + to_table 往返一致（归一消息恢复）。
    local rebuilt = conv.stack_from_table(bundle.messages)
    ctx.assert_same_table(rebuilt:to_table(), msgs, "messages round-trip through stack_from_table+to_table")
    -- runtime_state 保留（含透传字段与 usage）。
    ctx.assert_eq(bundle.runtime_state.generation, 2, "runtime_state.generation preserved")
    ctx.assert_eq(bundle.runtime_state.compact_protected_prefix_count, 1, "runtime_state passthrough preserved")
    ctx.assert_eq(bundle.runtime_state.usage.total_tokens, 42, "runtime_state.usage preserved")
    ctx.assert_eq(bundle.context_items[1].id, "ctx-9", "bundle context_items preserved")
    ctx.check(type(bundle.created_at) == "number" and type(bundle.updated_at) == "number", "bundle timestamps present")
  end

  -- 缺失/损坏路径：not_found typed error。
  local missing, merr = service:open("20260101_000000_001_000001_absent")
  ctx.check(missing == nil, "open missing returns nil")
  ctx.check(merr ~= nil and merr.cause and merr.cause.history_code == "not_found", "open missing typed not_found")
end)

if not ctx.ok then
  error("create-save-open failed: " .. table.concat(ctx.failures, "; "), 0)
end
print("HISTORY_OK: create-save-open")
