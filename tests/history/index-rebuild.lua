-- filepath: tests/history/index-rebuild.lua
--- history/index-rebuild: missing/corrupt index rebuilt from valid session files;
--- corrupt chat files are isolated (skipped with path+reason, NEVER deleted);
--- load_chat on a corrupt id returns nil + typed corrupt error.

local assert_mod = require("tests.history.lib.assert")
local fixture_project = require("tests.history.lib.fixture_project")
local history = require("maxa.runtime.history")

local ctx = assert_mod.new()

local function write_raw(path, text)
  local fh = assert(io.open(path, "wb"))
  fh:write(text)
  fh:close()
end

fixture_project.with_project(function(proj)
  local st = history.storage.new({ root = proj.root })

  local function make_env(save_id, updated_at)
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
      messages = { { role = "user", content = { { type = "text", text = save_id } } } },
      context_items = {},
      runtime_state = { generation = 1, cwd = proj.root, project_root = proj.root },
      trace = { id = nil, membership = {} },
      status_snapshot = {},
    }
  end

  local save_a = "20260806_100000_001_000001_rebuild_a"
  local save_b = "20260806_110000_001_000001_rebuild_b"
  ctx.check(st:save(make_env(save_a, 100)).ok == true, "save A ok")
  ctx.check(st:save(make_env(save_b, 200)).ok == true, "save B ok")

  -- 缺失 index -> 从有效会话文件重建。
  os.remove(st.index_path)
  ctx.check(vim.fn.filereadable(st.index_path) == 0, "index removed")
  local rb = st:rebuild_index()
  ctx.assert_eq(rb.rebuilt, 2, "rebuild rebuilt both chats")
  ctx.assert_eq(#rb.skipped, 0, "rebuild skipped nothing")
  local index = st:get_chats()
  ctx.check(index[save_a] ~= nil and index[save_b] ~= nil, "index recreated with both entries")

  -- 损坏一个会话文件：重建跳过且不删除；load_chat 返回类型化 corrupt。
  local chat_b = proj.history_dir .. "/chats/" .. save_b .. ".json"
  write_raw(chat_b, "not json {{{ garbage")
  local rb2 = st:rebuild_index()
  ctx.assert_eq(rb2.rebuilt, 1, "rebuild rebuilt only valid chat")
  ctx.assert_eq(#rb2.skipped, 1, "rebuild skipped corrupt chat")
  if rb2.skipped[1] then
    ctx.assert_eq(rb2.skipped[1].save_id, save_b, "skipped save_id")
    ctx.check(rb2.skipped[1].path == chat_b, "skipped path")
    ctx.check(type(rb2.skipped[1].reason) == "string" and #rb2.skipped[1].reason > 0, "skipped reason")
  end
  ctx.check(vim.fn.filereadable(chat_b) == 1, "corrupt chat file NOT deleted")
  local idx2 = st:get_chats()
  ctx.check(idx2[save_a] ~= nil and idx2[save_b] == nil, "index after rebuild has only valid chat")

  local benv, berr = st:load_chat(save_b)
  ctx.check(benv == nil, "corrupt chat load returns nil")
  ctx.check(berr ~= nil, "corrupt chat load returns typed error")
  if berr then
    ctx.assert_eq(berr.code, "persistence", "typed error code family")
    ctx.assert_eq(berr.cause.history_code, "corrupt", "typed error history code")
  end
  local aenv, aerr = st:load_chat(save_a)
  ctx.check(aenv ~= nil and aerr == nil, "valid chat still loads")

  -- 损坏 index：get_chats 优雅返回空；load 不依赖 index；重建可修复。
  write_raw(st.index_path, "corrupt index {{{")
  ctx.check(vim.tbl_isempty(st:get_chats()), "corrupt index -> empty get_chats")
  ctx.check(st:load_chat(save_a) ~= nil, "load_chat works with corrupt index")
  local rb3 = st:rebuild_index()
  ctx.assert_eq(rb3.rebuilt, 1, "rebuild after corrupt index rebuilt valid chat")
  ctx.check(st:get_chats()[save_a] ~= nil, "index repaired")
end)

if not ctx.ok then
  error("index-rebuild failed: " .. table.concat(ctx.failures, "; "), 0)
end
print("HISTORY_OK: index-rebuild")
