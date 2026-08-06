-- filepath: lua/maxa/runtime/history/init.lua
--- Phase-4 history 模块门面 + W2/W4 服务层（操作族）。
---
--- W1 提供存储层（storage/ids/migrate）；W2 在本文件实现 History 服务：
--- save/list/open/fork/scratch/merge/transfer/rewind/redo/title + auto-save 接线。
--- W3 追加 trace 子系统服务面（M.trace + start_trace/trace_read/backfill/
--- record_turn；bus 事件 trace.turn_recorded/trace.backfilled 由本层发出）。
--- W4 追加 compaction（Service:compact + compact.lua 纯策略模块 + trace
--- 压缩归档投影事件）与重启恢复（restore_bundle 完整恢复束；open 为其
--- 向后兼容别名）以及 history.* 服务事件投影（saved/save_failed/
--- saved_index_stale/restored/title_changed/compacted）。
--- W4-B 追加 host 接线支撑（additive，无行为变更）：`bind(session_id,
--- save_id)`（restore 后 save_id 连续性）、`bind_trace`/`trace_for`
--- （trace membership 服务侧映射）、`get_last_chat`（continue_last）、
--- 以及可后期赋值的 `snapshot_provider` 字段（host 在构造后注入视图
--- 快照组合；事件处理器优先读取该字段，回退 save_fn）。
---
--- 快照（snapshot）输入形状（由调用方构造；host/orchestrator 接线在 W4）：
---   { session_id, project_id, generation(number), provider_id, protocol, model,
---     title(string|nil), messages(Stack:to_table() 数组), context_items(table),
---     usage(map|nil), status_snapshot(map|nil), trace(map|nil: {id, membership}),
---     runtime_state?(map|nil: 透传字段，如 cwd/project_root/title_refresh_count) }
--- 服务由此构造 v1 信封（字段见 storage.validate_envelope）；index 的
--- cwd/project_root 来自信封 runtime_state（缺省为服务 root）。
---
--- 错误约定：存储失败原样透传（code 见 storage.CODES）；服务级校验失败返回
--- { ok=false, code=<服务级代码>, error=... }；open/load 类返回类型化错误
--- (schema.new_error(PERSISTENCE, ...)，cause.history_code 为模块级码)。

local schema = require("maxa.runtime.schema")
local ids = require("maxa.runtime.history.ids")
local storage_mod = require("maxa.runtime.history.storage")
local title_mod = require("maxa.runtime.history.title")
local trace_mod = require("maxa.runtime.history.trace")
local compact_mod = require("maxa.runtime.history.compact")

local M = {}

M.name = "history"

--- save_id / 标题 / 时间工具（无状态）。
M.ids = ids

--- 存储构造器（`M.storage.new({root=..., ...})` 返回 Storage 实例）。
M.storage = storage_mod

--- legacy 迁移（`M.migrate.migrate_file(storage, legacy_path)`）。
M.migrate = require("maxa.runtime.history.migrate")

--- 标题生成模块（`M.title.new({config, ids, provider_resolver})`）。
M.title = title_mod

--- trace 子系统（W3）：纯存储/查询库（manifest/events/index/membership/natural-turn/
--- backfill/read/synthesize/find/压缩归档）。服务层 trace 操作（start_trace/
--- trace_read/backfill/record_turn）见 Service 方法；本模块不 emit 事件。
M.trace = trace_mod

--- 压缩策略模块（W4）：纯策略/prompt（protected prefix / 模式解析 / 摘要 prompt）；
--- 编排在 `Service:compact`。
M.compact = compact_mod

--- 服务默认配置（history 配置段；host 在 W4 注入真实配置）。
local DEFAULTS = {
  auto_save = true,
  continue_last = false,
  title_provider = "auto", -- "auto" | "first_user" | "none"
  expiration_days = 0,
  title_generation_opts = { refresh_every_n_prompts = 0, max_refreshes = 3, format_title = nil },
}

local TITLE_PROVIDERS = { auto = true, first_user = true, none = true }

--- auto-save 订阅的既有事件名（W2 只允许订阅已存在事件；history.* 事件 W4 追加）。
local AUTO_SAVE_EVENTS = { "response.completed", "tool_batch.finished", "chat.soft_stop_completed", "chat.closed" }

local Service = {}
Service.__index = Service

--- 构造 History 服务。
---@param opts {root: string, config?: table, events?: table, clock?: fun():number,
---  conversation?: table, provider_resolver?: fun(ctx: table): table|nil,
---  save_fn?: fun(session_id: string, payload: table): table|nil,
---  snapshot_provider?: fun(session_id: string, payload: table): table|nil}
---@return table service
function M.new(opts)
  opts = opts or {}
  assert(type(opts.root) == "string" and opts.root ~= "", "history.new: root is required")
  local self = setmetatable({}, Service)
  local cfg = opts.config or {}
  self.storage = storage_mod.new({ root = opts.root, expiration_days = cfg.expiration_days })
  self.config = vim.tbl_deep_extend("force", vim.deepcopy(DEFAULTS), cfg)
  if not TITLE_PROVIDERS[self.config.title_provider] then
    self.config.title_provider = "auto"
  end
  self.events = opts.events or require("maxa.runtime.events")
  self.clock = opts.clock or function()
    return os.time()
  end
  self.conversation = opts.conversation or require("maxa.runtime.conversation")
  self.provider_resolver = opts.provider_resolver
  -- W4-B: the host auto-save wiring sets `service.snapshot_provider` AFTER
  -- construction (assembly cannot know the host's views); the event handler
  -- prefers this field and falls back to the constructor-injected save_fn.
  self.snapshot_provider = opts.snapshot_provider or opts.save_fn
  self.save_fn = self.snapshot_provider
  self.title_generator = title_mod.new({ config = self.config, ids = ids, provider_resolver = self.provider_resolver })
  -- compact 策略实例（命名避开 Service:compact 方法：实例字段会遮蔽元表方法）。
  self.compact_policy = compact_mod.new({
    config = self.config,
    ids = ids,
    storage = self.storage,
    trace = trace_mod,
    provider_resolver = self.provider_resolver,
  })
  self._save_ids = {} -- session_id -> save_id（活动绑定）
  self._unsavable = {} -- session_id -> unsavable save_id
  self._traces = {} -- session_id -> trace {id, membership}（restore 接线，W4-B）
  self._listeners = {} -- unsubscribe fns
  self._listening = false
  return self
end

---@return number 当前时间（注入 clock；缺省 os.time() 秒）。
function Service:_now()
  return self.clock()
end

---@return string history 目录
function Service:history_dir()
  return self.storage:get_location()
end

--- 快照最小校验；通过返回 nil，失败返回错误字符串。
function Service:_validate_snapshot(snapshot)
  if type(snapshot) ~= "table" then
    return "snapshot must be a table"
  end
  if type(snapshot.session_id) ~= "string" or snapshot.session_id == "" then
    return "snapshot.session_id must be a non-empty string"
  end
  if type(snapshot.project_id) ~= "string" or snapshot.project_id == "" then
    return "snapshot.project_id must be a non-empty string"
  end
  for _, f in ipairs({ "provider_id", "protocol", "model" }) do
    if type(snapshot[f]) ~= "string" then
      return "snapshot." .. f .. " must be a string"
    end
  end
  if type(snapshot.messages) ~= "table" or not vim.islist(snapshot.messages) then
    return "snapshot.messages must be an array"
  end
  return nil
end

--- 由快照构造 v1 信封。
---@param snapshot table
---@param save_id string
---@param opts {generation?: number, created_at?: number, cwd?: string, project_root?: string}
---@return table env
function Service:_build_envelope(snapshot, save_id, opts)
  opts = opts or {}
  local rs = {}
  if snapshot.runtime_state ~= nil then
    rs = vim.deepcopy(snapshot.runtime_state)
  end
  rs.generation = tonumber(opts.generation ~= nil and opts.generation or snapshot.generation) or 0
  rs.cwd = snapshot.cwd or rs.cwd or opts.cwd or self.storage.root
  rs.project_root = snapshot.project_root or rs.project_root or opts.project_root or self.storage.root
  if snapshot.usage ~= nil then
    rs.usage = vim.deepcopy(snapshot.usage)
  elseif rs.usage == nil then
    rs.usage = {}
  end
  -- trace 深拷贝：信封持久化 trace {id, membership}（membership 随信封落盘，
  -- 恢复时写回 session 元数据）。W3 起 membership 为拷贝值，避免快照共享突变。
  local trace = { id = nil, membership = {} }
  if type(snapshot.trace) == "table" then
    trace = { id = snapshot.trace.id or nil, membership = vim.deepcopy(snapshot.trace.membership or {}) }
  end
  return {
    schema_version = storage_mod.SCHEMA_VERSION,
    session_id = snapshot.session_id,
    save_id = save_id,
    project_id = snapshot.project_id,
    parent_session_id = snapshot.parent_session_id or nil,
    created_at = tonumber(opts.created_at) or self:_now(),
    updated_at = self:_now(),
    title = snapshot.title or nil,
    provider_id = snapshot.provider_id,
    protocol = snapshot.protocol,
    model = snapshot.model,
    messages = snapshot.messages,
    context_items = snapshot.context_items or {},
    runtime_state = rs,
    trace = trace,
    status_snapshot = snapshot.status_snapshot or {},
  }
end

--- 保存快照：组包 v1 信封 + 绑定 session_id -> save_id（auto-save 去重）。
--- 同 save_id 重存保留首次 created_at（稳定身份）；stale generation 由 storage 拒绝。
---@param snapshot table
---@param opts {save_id?: string, promote?: string, generation?: number, created_at?: number, cwd?: string, project_root?: string}
---@return table result {ok=true, save_id=string, status="saved"} | 存储错误结果
function Service:save(snapshot, opts)
  opts = opts or {}
  local verr = self:_validate_snapshot(snapshot)
  if verr then
    local fail = { ok = false, code = "invalid_snapshot", error = verr }
    self:_emit_history_event("history.save_failed", {
      session_id = type(snapshot) == "table" and snapshot.session_id or nil,
      code = fail.code,
      error = verr,
    })
    return fail
  end
  local session_id = snapshot.session_id
  local bound = self._save_ids[session_id]
  local save_id
  local promoted = false
  if opts.promote ~= nil then
    -- scratch 转正：opts.promote 必须匹配绑定的 unsavable id（存于 _unsavable）。
    local unsavable = self._unsavable[session_id]
    if unsavable ~= opts.promote or not ids.is_unsavable_save_id(unsavable or "") then
      local fail = {
        ok = false,
        code = "promote_mismatch",
        error = "opts.promote does not match bound unsavable save_id",
      }
      self:_emit_history_event("history.save_failed", { session_id = session_id, code = fail.code, error = fail.error })
      return fail
    end
    save_id = ids.generate_save_id({ history_dir = self:history_dir() })
    promoted = true
  else
    save_id = bound or opts.save_id or ids.generate_save_id({ history_dir = self:history_dir() })
  end
  -- 稳定身份：同 save_id 重存时保留首次 created_at。
  local build_opts = vim.deepcopy(opts)
  if opts.created_at == nil and bound ~= nil and bound == save_id and not promoted then
    local durable, _ = self.storage:load_chat(save_id)
    if durable then
      build_opts.created_at = durable.created_at
    end
  end
  local env = self:_build_envelope(snapshot, save_id, build_opts)
  -- W4：调用方可注入信封补丁（如 compact 把 protected prefix 计数镜像进
  -- envelope.opts），在持久化前应用。
  if type(opts.envelope_patch) == "function" then
    opts.envelope_patch(env)
  end
  local res = self.storage:save(env)
  if not res.ok then
    if res.code == storage_mod.CODES.INDEX_STALE then
      self:_emit_history_event("history.saved_index_stale", {
        save_id = res.save_id,
        session_id = session_id,
        code = res.code,
        error = res.error,
      })
    else
      self:_emit_history_event("history.save_failed", {
        save_id = res.save_id,
        session_id = session_id,
        code = res.code,
        error = res.error,
      })
    end
    return res
  end
  if promoted then
    self._unsavable[session_id] = nil
  end
  self._save_ids[session_id] = save_id
  self:_emit_history_event("history.saved", {
    save_id = save_id,
    session_id = session_id,
    status = "saved",
    generation = (env.runtime_state and env.runtime_state.generation) or 0,
  })
  return { ok = true, save_id = save_id, status = "saved" }
end

--- 列出 index 条目（委托 storage.get_chats）。
---@param filter? fun(entry: table): boolean
---@return table<string, table>
function Service:list(filter)
  return self.storage:get_chats(filter)
end

--- 打开已保存会话，返回完整恢复束（W4 restart-recovery 的权威入口）。
--- 信封字段逐字透传：messages/runtime_state（含 loop.decisions/usage/
--- title_refresh_count/compact_protected_prefix_count）/trace{id,membership}/
--- status_snapshot/context_items。host wave 据此重建 Session:restore +
--- stack_from_table；view 缺席/MCP 不可用在本层不相关。
--- 缺失返回 typed error(not_found)；损坏返回 typed error(corrupt)。
---@param save_id string
---@return table|nil bundle {save_id, session_id, project_id, parent_session_id, title,
---  provider_id, protocol, model, messages, context_items, runtime_state, trace,
---  status_snapshot, created_at, updated_at}
---@return table|nil err typed error
function Service:restore_bundle(save_id)
  local env, err = self.storage:load_chat(save_id)
  if not env then
    if err then
      return nil, err
    end
    return nil,
      schema.new_error(
        schema.ERROR.PERSISTENCE,
        "history.open: no chat with save_id " .. tostring(save_id),
        { history_code = "not_found" }
      )
  end
  local bundle = {
    save_id = env.save_id,
    session_id = env.session_id,
    project_id = env.project_id,
    parent_session_id = env.parent_session_id,
    title = env.title,
    provider_id = env.provider_id,
    protocol = env.protocol,
    model = env.model,
    messages = env.messages,
    context_items = env.context_items,
    runtime_state = env.runtime_state,
    trace = env.trace,
    status_snapshot = env.status_snapshot,
    created_at = env.created_at,
    updated_at = env.updated_at,
  }
  self:_emit_history_event("history.restored", { save_id = env.save_id, session_id = env.session_id })
  return bundle, nil
end

--- open：restore_bundle 的向后兼容别名（W2 既有调用面保持不变）。
---@param save_id string
---@return table|nil bundle
---@return table|nil err typed error
function Service:open(save_id)
  return self:restore_bundle(save_id)
end

--- fork：新 save_id + parent_session_id；复制 messages/context_items/provider/model；
--- runtime_state.generation 重置 0；trace 复制（membership 原样，trace.id 保留，
--- W3 补 span 语义）。子会话独立可变（不同 save_id，不绑定本服务 session 映射）。
---@param snapshot table
---@param opts {parent_save_id?: string}
---@return table result {ok=true, save_id=string, parent_session_id=string, status="saved"} | 错误结果
function Service:fork(snapshot, opts)
  opts = opts or {}
  local verr = self:_validate_snapshot(snapshot)
  if verr then
    return { ok = false, code = "invalid_snapshot", error = verr }
  end
  local parent_save_id = opts.parent_save_id or snapshot.session_id
  local save_id = ids.generate_save_id({ history_dir = self:history_dir() })
  local child = vim.deepcopy(snapshot)
  child.title = snapshot.title or ids.get_chat_title(snapshot.messages)
  local env = self:_build_envelope(child, save_id, { generation = 0 })
  env.parent_session_id = parent_save_id
  -- fork trace 语义（W3，对齐实施计划 §4 fork 行）：复制 membership 但生成新 span，
  -- parent_span_id 指向源 span；root_trace_id 共享。
  local src_trace = snapshot.trace
  if type(src_trace) == "table" and src_trace.id then
    local source_holder = { trace = { id = src_trace.id, membership = vim.deepcopy(src_trace.membership or {}) } }
    local target_holder = { trace = { id = src_trace.id, membership = {} } }
    local membership, merr = trace_mod.copy_membership(source_holder, target_holder, { new_span = true })
    if type(membership) == "table" then
      env.trace = { id = src_trace.id, membership = membership }
    elseif merr then
      -- 复制失败（源 membership 缺失 root_trace_id）：保留 id，membership 空表。
      env.trace = { id = src_trace.id, membership = {} }
    end
  end
  local res = self.storage:save(env)
  if not res.ok then
    return res
  end
  return { ok = true, save_id = save_id, parent_session_id = parent_save_id, status = "saved" }
end

--- scratch：不可保存 save_id（含 `/`，路径校验拒绝落盘）；不写文件、不建 index。
--- 显式 save(snapshot, {promote=unsavable_id}) 转正（生成新 save_id）。
---@param snapshot table|nil
---@param opts {session_id?: string}
---@return table result {save_id=string, unsavable=true} | {ok=false, code=..., error=...}
function Service:scratch(snapshot, opts)
  opts = opts or {}
  local session_id = (snapshot and snapshot.session_id) or opts.session_id
  if type(session_id) ~= "string" or session_id == "" then
    return { ok = false, code = "invalid_snapshot", error = "scratch requires snapshot.session_id or opts.session_id" }
  end
  local save_id = ids.make_unsavable_save_id("scratch")
  self._unsavable[session_id] = save_id
  return { save_id = save_id, unsavable = true }
end

--- merge：从源会话选择精确消息范围（1-based 闭区间，逐源顺序），每条插入消息
--- 附加 provenance {source_save_id, range=[start,end]}，追加到目标快照后保存。
--- opts.close_source 默认 true：服务层返回 {closed=true}（实际视图关闭由 host 负责）。
---@param target_snapshot table
---@param sources table[] {save_id: string, start_index: integer, end_index: integer}
---@param opts {close_source?: boolean}
---@return table result {ok=true, target_save_id=string, closed=boolean, status="saved"} | 错误结果
function Service:merge(target_snapshot, sources, opts)
  opts = opts or {}
  local verr = self:_validate_snapshot(target_snapshot)
  if verr then
    return { ok = false, code = "invalid_snapshot", error = verr }
  end
  if type(sources) ~= "table" or #sources == 0 then
    return {
      ok = false,
      code = "invalid_merge",
      error = "sources must be a non-empty array of {save_id, start_index, end_index}",
    }
  end
  local merged = {}
  for _, src in ipairs(sources) do
    if type(src) ~= "table" or type(src.save_id) ~= "string" then
      return { ok = false, code = "invalid_merge", error = "source entry must be a table with save_id" }
    end
    local env, lerr = self.storage:load_chat(src.save_id)
    if not env then
      if lerr then
        return { ok = false, code = lerr.cause and lerr.cause.history_code or "corrupt", error = lerr.message }
      end
      return { ok = false, code = "not_found", error = "merge source not found: " .. src.save_id }
    end
    local start_i = tonumber(src.start_index)
    local end_i = tonumber(src.end_index)
    local total = #(env.messages or {})
    if not start_i or not end_i or start_i < 1 or end_i < start_i or end_i > total then
      return {
        ok = false,
        code = "invalid_merge",
        error = ("invalid range %s..%s for %s (has %d messages)"):format(
          tostring(start_i),
          tostring(end_i),
          src.save_id,
          total
        ),
      }
    end
    for i = start_i, end_i do
      local msg = vim.deepcopy(env.messages[i])
      local prov = msg.provenance
      if type(prov) ~= "table" then
        prov = {}
      end
      msg.provenance = prov
      prov[#prov + 1] = { source_save_id = src.save_id, range = { start_i, end_i } }
      merged[#merged + 1] = msg
    end
  end
  local target = vim.deepcopy(target_snapshot)
  target.messages = vim.deepcopy(target_snapshot.messages or {})
  for _, msg in ipairs(merged) do
    target.messages[#target.messages + 1] = msg
  end
  local save_res = self:save(target)
  if not save_res.ok then
    return save_res
  end
  local close_source = opts.close_source ~= false
  return {
    ok = true,
    save_id = save_res.save_id,
    target_save_id = save_res.save_id,
    status = save_res.status,
    closed = close_source,
  }
end

--- transfer：copy/move 到目标项目 `<target_project_root>/.maxa/history`。
--- 目标信封带 runtime_state.transfer provenance（mode/source_project_root/
--- source_history_dir/source_save_id/source_cwd/transferred_at）；新 save_id；
--- move 仅在目标会话文件 + 目标 index 提交成功后删除源。
---@param save_id string
---@param target_project_root string
---@param opts {mode?: "copy"|"move", title?: string}
---@return table result {ok=true, mode=string, target_save_id=string, target_project_root=string,
---  target_history_dir=string, source_deleted=boolean, transferred_at=number, title=string} | 错误结果
function Service:transfer(save_id, target_project_root, opts)
  opts = opts or {}
  local mode = opts.mode or "copy"
  if mode ~= "copy" and mode ~= "move" then
    return { ok = false, code = "invalid_transfer", error = "mode must be copy or move" }
  end
  if type(target_project_root) ~= "string" or target_project_root == "" then
    return { ok = false, code = "invalid_transfer", error = "target_project_root must be a non-empty string" }
  end
  local source_env, lerr = self.storage:load_chat(save_id)
  if not source_env then
    if lerr then
      return { ok = false, code = lerr.cause and lerr.cause.history_code or "corrupt", error = lerr.message }
    end
    return { ok = false, code = "not_found", error = "transfer source not found: " .. save_id }
  end
  local ok_new, target_storage = pcall(storage_mod.new, { root = target_project_root })
  if not ok_new then
    return { ok = false, code = "invalid_transfer", error = "target project root invalid: " .. tostring(target_storage) }
  end
  local transferred_at = self:_now()
  local target_save_id = ids.generate_save_id({ history_dir = target_storage.history_dir })
  local target_env = vim.deepcopy(source_env)
  target_env.save_id = target_save_id
  target_env.updated_at = transferred_at
  target_env.runtime_state = vim.deepcopy(target_env.runtime_state or {})
  target_env.runtime_state.cwd = target_project_root
  target_env.runtime_state.project_root = target_project_root
  target_env.runtime_state.transfer = {
    mode = mode,
    source_project_root = self.storage.root,
    source_history_dir = self.storage.history_dir,
    source_save_id = save_id,
    source_cwd = source_env.runtime_state and source_env.runtime_state.cwd,
    transferred_at = transferred_at,
  }
  if type(opts.title) == "string" and opts.title ~= "" then
    target_env.title = opts.title
  end
  local tres = target_storage:save(target_env)
  if not tres.ok then
    -- 证据语义：目标 index 提交失败时删除已写入的目标会话文件。
    pcall(os.remove, target_storage.chats_dir .. "/" .. target_save_id .. ".json")
    return tres
  end
  local source_deleted = false
  if mode == "move" then
    local del_ok = self.storage:delete_chat(save_id)
    if not del_ok then
      return { ok = false, code = "write_failed", error = "target written but failed to delete source: " .. save_id }
    end
    source_deleted = true
  end
  return {
    ok = true,
    mode = mode,
    target_save_id = target_save_id,
    target_project_root = target_project_root,
    target_history_dir = target_storage.history_dir,
    source_deleted = source_deleted,
    transferred_at = transferred_at,
    title = target_env.title,
  }
end

--- rewind：截断到最后一条 manual user 消息（保留该消息及之前内容），
--- generation+1 保存（orchestrator 约定：截断即新 generation）。
---@param snapshot table
---@param opts table|nil
---@return table result {ok=true, save_id=string, truncated_count=integer, status="saved"} | 错误结果
function Service:rewind(snapshot, opts)
  opts = opts or {}
  local verr = self:_validate_snapshot(snapshot)
  if verr then
    return { ok = false, code = "invalid_snapshot", error = verr }
  end
  local stack = self.conversation.stack_from_table(snapshot.messages or {})
  local removed = stack:truncate_after_last_user()
  local truncated_count = removed and #removed or 0
  local next_snapshot = vim.deepcopy(snapshot)
  next_snapshot.messages = stack:to_table()
  next_snapshot.generation = (tonumber(snapshot.generation) or 0) + 1
  local res = self:save(next_snapshot, { generation = next_snapshot.generation })
  if not res.ok then
    return res
  end
  return { ok = true, save_id = res.save_id, truncated_count = truncated_count, status = "saved" }
end

--- redo：数据侧实现——由 snapshot.messages 重建 stack（stack_from_table 校验）并
--- 返回重建消息；真实提交（恰一次，kind=restore）由 W4 经 restore 接线。
--- 服务级幂等：无状态变更，重复调用返回相同结果。
---@param snapshot table
---@param opts table|nil
---@return table result {ok=true, save_id=string|nil, submitted=true, messages=table[]}
function Service:redo(snapshot, opts)
  opts = opts or {}
  local verr = self:_validate_snapshot(snapshot)
  if verr then
    return { ok = false, code = "invalid_snapshot", error = verr }
  end
  local stack = self.conversation.stack_from_table(snapshot.messages or {})
  return {
    ok = true,
    save_id = self._save_ids[snapshot.session_id] or nil,
    submitted = true,
    messages = stack:to_table(),
  }
end

--- compact：压缩服务操作（W4 compaction，编排层；策略见 history/compact.lua）。
--- 语义（对齐 evidence history_session.apply_compression_result + 实施计划 §2.9）：
---   * protected prefix（runtime_state.compact_protected_prefix_count）前的可见
---     user 轮次绝不归档/移除；显式 opts.range 与 protected 区域重叠 -> 拒绝；
---   * 摘要缺失时经 provider_resolver -> provider.request(prompt, cb) 生成
---     （provider 接口与 title 相同；LLM 失败返回 summary_failed 且不持久化
---     任何内容——归档与保存都不发生）；
---   * TRACE ORDER（H-004）：先 archive_compression_range（dedupe_key 去重），
---     再 append_compression_applied，最后保存新 generation——归档先于会话
---     指向新消息；untracked（无 trace membership）会话跳过 trace 步骤；
---   * mode auto：已保存会话 -> overwrite；opts.is_current=true -> new；
---     overwrite 保留 save_id（generation+1，created_at 稳定）；new 生成
---     `compact_` 前缀 save_id（generation+1）+ compression provenance meta
---     {compressed_from, compressed_at, previous}。
---@param snapshot table
---@param opts {mode?: "auto"|"overwrite"|"new", range?: {start_index: integer, end_index: integer},
---  summary?: string, provider_resolver?: fun(ctx: table): table|nil, is_current?: boolean,
---  source_type?: string, action?: string, save_id?: string, range_index?: integer}
---@return table result {ok=true, action="overwrite"|"new", save_id, generation,
---  truncated_count, archived, trace_id} | {ok=false, code, error}
function Service:compact(snapshot, opts)
  opts = opts or {}
  local verr = self:_validate_snapshot(snapshot)
  if verr then
    return { ok = false, code = "invalid_snapshot", error = verr }
  end
  local messages = snapshot.messages or {}
  local action = compact_mod.apply_modes(opts.mode or "auto", { is_current = opts.is_current })
  if not action then
    return {
      ok = false,
      code = "invalid_mode",
      error = "compact mode must be auto, overwrite or new (got " .. tostring(opts.mode) .. ")",
    }
  end
  local protected_count = self.compact_policy:protected_prefix_count(snapshot)
  local protected_end = self.compact_policy:compute_protected_boundary(messages, protected_count)
  local range
  if opts.range then
    local start_i = math.floor(tonumber(opts.range.start_index) or -1)
    local end_i = math.floor(tonumber(opts.range.end_index) or -1)
    if start_i < 1 or end_i < start_i or end_i > #messages then
      return {
        ok = false,
        code = "invalid_range",
        error = ("invalid compaction range [%s,%s] for %d messages"):format(
          tostring(start_i),
          tostring(end_i),
          #messages
        ),
      }
    end
    if start_i <= protected_end then
      return {
        ok = false,
        code = "protected_prefix_overlap",
        error = ("compaction range start %d overlaps protected prefix through index %d"):format(start_i, protected_end),
      }
    end
    range = { start_index = start_i, end_index = end_i }
  else
    local start_i = protected_end + 1
    if start_i > #messages then
      return { ok = false, code = "nothing_to_compact", error = "no messages outside the protected prefix" }
    end
    range = { start_index = start_i, end_index = #messages }
  end

  -- 摘要：显式 summary 优先；否则经 provider 生成（同步 provider；失败零持久化）。
  local summary = opts.summary
  if type(summary) ~= "string" or vim.trim(summary) == "" then
    local prompt = self.compact_policy:build_summary_prompt(messages, { range = range })
    local resolver = opts.provider_resolver or self.provider_resolver
    local provider = nil
    if resolver then
      provider = resolver({ snapshot = snapshot, range = range, mode = opts.mode or "auto", action = action })
    end
    if not provider or type(provider.request) ~= "function" then
      return { ok = false, code = "summary_failed", error = "no summary provider" }
    end
    local done = false
    local callback_result = nil
    provider.request(prompt, function(text, err)
      done = true
      callback_result = { text = text, err = err }
    end)
    if not done then
      return { ok = false, code = "summary_failed", error = "summary provider did not return synchronously" }
    end
    if callback_result.err then
      return { ok = false, code = "summary_failed", error = tostring(callback_result.err) }
    end
    if type(callback_result.text) ~= "string" or vim.trim(callback_result.text) == "" then
      return { ok = false, code = "summary_failed", error = "empty summary result" }
    end
    summary = vim.trim(callback_result.text)
  end

  -- save_id 解析：overwrite 要求已绑定/显式 durable save_id；new 生成 compact_ 前缀。
  local original_save_id = opts.save_id or self._save_ids[snapshot.session_id] or snapshot.save_id or nil
  local target_save_id
  if action == "new" then
    target_save_id = ids.generate_save_id({ history_dir = self:history_dir(), prefix = "compact" })
  else
    if type(original_save_id) ~= "string" or original_save_id == "" or ids.is_unsavable_save_id(original_save_id) then
      return { ok = false, code = "no_save_id", error = "compact overwrite requires a durable save_id" }
    end
    target_save_id = original_save_id
  end

  -- trace 步骤：归档先于会话指向新 generation（H-004）；untracked 零写入。
  local archived = { tracked = false }
  local trace_id = type(snapshot.trace) == "table" and snapshot.trace.id or nil
  if trace_id then
    local source = {
      messages = messages,
      save_id = original_save_id,
      source_type = opts.source_type or "saved",
      trace = { id = trace_id, membership = vim.deepcopy(snapshot.trace.membership or {}) },
    }
    local archive_result, aerr = trace_mod.archive_compression_range(self:history_dir(), trace_id, source, range, {
      tool_name = "compact",
      mode = opts.mode or "auto",
      action = opts.action or "compact",
      range_index = opts.range_index,
    })
    if not archive_result then
      return { ok = false, code = "archive_failed", error = tostring(aerr) }
    end
    archived = archive_result
    if archived.tracked then
      self:_emit_trace_event("trace.archive_created", {
        root_trace_id = trace_id,
        event_id = archived.event_id,
        kind = "compression.archive_created",
      })
      local applied, aperr = trace_mod.append_compression_applied(self:history_dir(), trace_id, source, {
        tool_name = "compact",
        mode = opts.mode or "auto",
        action = action,
        source_save_id = original_save_id,
        new_save_id = action == "new" and target_save_id or nil,
        original_save_id = original_save_id,
        stats = {
          truncated_count = range.end_index - range.start_index + 1,
          archived_turn_count = archived.turn_count or 0,
        },
        archives = { archive_result },
      })
      if not applied then
        return { ok = false, code = "archive_failed", error = tostring(aperr) }
      end
      archived.applied = applied
      self:_emit_trace_event("trace.compression_applied", {
        root_trace_id = trace_id,
        event_id = applied.event_id,
        action = action,
      })
    end
  end

  -- 替换消息：protected 区域（逐字保留）+ compact_summary 摘要消息
  -- （tag 在 trace IGNORED_TAGS 内，不构成 natural turn）+ overwrite 尾部保留。
  local truncated_count = range.end_index - range.start_index + 1
  local next_snapshot = vim.deepcopy(snapshot)
  next_snapshot.messages = {}
  for i = 1, protected_end do
    next_snapshot.messages[i] = vim.deepcopy(messages[i])
  end
  next_snapshot.messages[#next_snapshot.messages + 1] = {
    role = "user",
    content = { { type = "text", text = summary } },
    _meta = { tag = compact_mod.SUMMARY_TAG },
  }
  if action == "overwrite" then
    for i = range.end_index + 1, #messages do
      next_snapshot.messages[#next_snapshot.messages + 1] = vim.deepcopy(messages[i])
    end
  end
  local next_gen = (tonumber(snapshot.generation) or 0) + 1
  next_snapshot.generation = next_gen
  next_snapshot.runtime_state = vim.deepcopy(snapshot.runtime_state or {})
  next_snapshot.runtime_state.compact_protected_prefix_count = protected_count
  local existing_provenance = next_snapshot.runtime_state.compression_provenance
  next_snapshot.runtime_state.compression_provenance = {
    compressed_from = original_save_id or nil,
    compressed_at = self:_now(),
    previous = vim.deepcopy(existing_provenance) or nil,
  }

  -- new 模式：目标 save_id 是显式新 id，会话绑定不得遮蔽它（save() 解析
  -- save_id = bound or opts.save_id）；先临时解绑，失败时恢复原绑定。
  local previous_bound = self._save_ids[snapshot.session_id]
  if action == "new" then
    self._save_ids[snapshot.session_id] = nil
  end
  local save_res = self:save(next_snapshot, {
    save_id = target_save_id,
    generation = next_gen,
    envelope_patch = function(env)
      compact_mod.set_protected_prefix_count(env, protected_count)
    end,
  })
  if action == "new" and not save_res.ok then
    self._save_ids[snapshot.session_id] = previous_bound
  end
  if not save_res.ok then
    return save_res -- save_failed / saved_index_stale 已由 save() 发出
  end
  local result = {
    ok = true,
    action = action,
    save_id = save_res.save_id,
    generation = next_gen,
    truncated_count = truncated_count,
    archived = archived,
    trace_id = trace_id,
  }
  self:_emit_history_event("history.compacted", {
    save_id = save_res.save_id,
    session_id = snapshot.session_id,
    action = action,
    generation = next_gen,
    truncated_count = truncated_count,
    archived = archived,
  })
  return result
end

--- 当前绑定 save_id（正规或 unsavable；无绑定返回 nil）。
---@param session_id string
---@return string|nil
function Service:current_save_id(session_id)
  return self._save_ids[session_id] or self._unsavable[session_id] or nil
end

--- W4-B：显式绑定 session_id -> 正规 save_id（host restore 流程使用）。
--- 恢复后调用，使后续 auto_save / close-save 写入同一 save_id ——
--- save -> close -> reopen 连续性依赖该绑定。拒绝 unsavable id 与空 id
--- （unsavable 会话仍走 _unsavable 映射，不得被本方法覆盖）。
---@param session_id string
---@param save_id string
---@return table self
function Service:bind(session_id, save_id)
  if
    type(session_id) == "string"
    and session_id ~= ""
    and type(save_id) == "string"
    and save_id ~= ""
    and not ids.is_unsavable_save_id(save_id)
  then
    self._save_ids[session_id] = save_id
  end
  return self
end

--- W4-B：显式绑定 session_id -> trace {id, membership}（host restore 流程使用）。
--- 恢复后调用，使 host 的 snapshot_provider 组包快照时经 `trace_for` 取回
--- trace membership，从而 auto_save / close-save 持续携带同一 trace。
---@param session_id string
---@param trace table|nil {id?: string, membership?: table}
---@return table self
function Service:bind_trace(session_id, trace)
  if type(session_id) == "string" and session_id ~= "" then
    if type(trace) == "table" then
      self._traces[session_id] = {
        id = type(trace.id) == "string" and trace.id or nil,
        membership = vim.deepcopy(trace.membership or {}),
      }
    else
      self._traces[session_id] = nil
    end
  end
  return self
end

--- W4-B：读取 session 的 trace 映射（bind_trace 写入；未绑定返回 nil）。
---@param session_id string
---@return table|nil trace {id?: string, membership?: table}
function Service:trace_for(session_id)
  if type(session_id) ~= "string" or session_id == "" then
    return nil
  end
  local tr = self._traces[session_id]
  if not tr then
    return nil
  end
  return { id = tr.id, membership = vim.deepcopy(tr.membership or {}) }
end

--- W4-B：最近更新的已保存会话（按 index updated_at；continue_last 使用）。
--- 委托 storage.get_last_chat；返回完整信封（含 messages/runtime_state）。
---@param filter_fn? fun(entry: table): boolean
---@return table|nil envelope
---@return table|nil err typed error
function Service:get_last_chat(filter_fn)
  return self.storage:get_last_chat(filter_fn)
end

--- 在服务 bus 上 emit trace 投影事件（bus 缺席时安全跳过）。
---@param name string
---@param payload table
function Service:_emit_trace_event(name, payload)
  if self.events and type(self.events.emit) == "function" then
    self.events.emit(name, payload)
  end
end

--- 在服务 bus 上 emit history 生命周期投影事件（bus 缺席时安全跳过）。
---@param name string history.saved / history.save_failed / history.saved_index_stale /
---  history.restored / history.title_changed / history.compacted
---@param payload table
function Service:_emit_history_event(name, payload)
  if self.events and type(self.events.emit) == "function" then
    self.events.emit(name, payload)
  end
end

--- trace start：创建 manifest + 根 membership。
--- root_trace_id 解析：opts.root_trace_id > snapshot.save_id（真实 save_id 时）>
--- 生成新 id（unsavable/缺席时；trace id 永不为 unsavable）。不落盘 membership
--- 本体——调用方把返回 membership 挂到 snapshot.trace 后经 save 持久化进信封。
---@param snapshot table|nil
---@param opts? {root_trace_id?: string, root_save_id?: string, root_title?: string,
---  span_id?: string, session_role?: string, source?: string}
---@return table result {ok=true, root_trace_id=string, membership=table} | 错误结果
function Service:start_trace(snapshot, opts)
  opts = opts or {}
  local root_trace_id = opts.root_trace_id
  if not root_trace_id and type(snapshot) == "table" then
    local save_id = snapshot.save_id
    if
      type(save_id) == "string"
      and save_id ~= ""
      and not ids.is_unsavable_save_id(save_id)
      and not save_id:match("[/\\]")
    then
      root_trace_id = save_id
    end
  end
  if not root_trace_id then
    root_trace_id = ids.generate_save_id({ history_dir = self:history_dir(), prefix = "trace" })
  end
  local manifest, merr = trace_mod.ensure_manifest(self:history_dir(), root_trace_id, {
    root_save_id = opts.root_save_id or root_trace_id,
    root_title = type(snapshot) == "table" and snapshot.title or opts.root_title or nil,
    source = opts.source or "trace_start",
  })
  if not manifest then
    return { ok = false, code = "trace_start_failed", error = tostring(merr) }
  end
  local membership = trace_mod.create_root_membership(root_trace_id, opts)
  return { ok = true, root_trace_id = root_trace_id, membership = membership }
end

--- trace 读取（自动路由）：root_trace_id 直读 recorded；save_id 经
--- find_trace_id_for_save_id（direct/chat_meta/index）解析；均无则回退
--- synthesize_trace（saved chat 合成）。返回结果带 source 字段供调用方区分。
---@param id string root_trace_id 或 save_id
---@param opts? {mode?: "summary"|"full", skip?: integer, take?: integer, include_archives?: boolean}
---@return table|nil result
---@return table|nil err typed error
function Service:trace_read(id, opts)
  opts = opts or {}
  if type(id) ~= "string" or id == "" then
    return nil,
      schema.new_error(
        schema.ERROR.INVALID_ARGUMENT,
        "history.trace_read: id must be a non-empty root_trace_id or save_id",
        { history_code = "invalid_trace_id" }
      )
  end
  if trace_mod.trace_exists(self:history_dir(), id) then
    local res, terr = trace_mod.read_trace(self:history_dir(), id, opts)
    if not res then
      return nil,
        schema.new_error(
          schema.ERROR.PERSISTENCE,
          "history.trace_read: " .. tostring(terr),
          { history_code = "trace_read_failed" }
        )
    end
    return res, nil
  end
  local trace_id, source = trace_mod.find_trace_id_for_save_id(self:history_dir(), id)
  if trace_id then
    local res, terr = trace_mod.read_trace(self:history_dir(), trace_id, opts)
    if not res then
      return nil,
        schema.new_error(
          schema.ERROR.PERSISTENCE,
          "history.trace_read: " .. tostring(terr),
          { history_code = "trace_read_failed" }
        )
    end
    res.resolved_from = source
    return res, nil
  end
  local res, serr = trace_mod.synthesize_trace(self:history_dir(), id, opts)
  if not res then
    if serr then
      return nil,
        schema.new_error(
          schema.ERROR.PERSISTENCE,
          "history.trace_read: " .. tostring(serr),
          { history_code = "trace_not_found" }
        )
    end
    return nil,
      schema.new_error(schema.ERROR.PERSISTENCE, "history.trace_read: no trace or saved chat for " .. tostring(id), {
        history_code = "trace_not_found",
      })
  end
  return res, nil
end

--- backfill：对 snapshot 的 trace 幂等回填可见 natural turns + summary 事件。
--- trace id 取自 snapshot.trace.id；缺失时按 trace start 语义创建
--- （root_trace_id = snapshot.save_id 或生成）并返回 membership。
---@param snapshot table
---@param opts? {root_trace_id?: string, membership?: table}
---@return table result trace_mod.backfill_chat 结果 {added, skipped, errors,
---  total_candidates, backfill_event_added?/backfill_event_skipped?}
function Service:backfill(snapshot, opts)
  opts = opts or {}
  if type(snapshot) ~= "table" then
    return {
      added = 0,
      skipped = 0,
      errors = { { error = "invalid_snapshot: snapshot must be a table" } },
      total_candidates = 0,
    }
  end
  local trace_id = opts.root_trace_id
  local membership = opts.membership
  if not trace_id and type(snapshot.trace) == "table" then
    trace_id = snapshot.trace.id
    membership = membership or snapshot.trace.membership
  end
  if not trace_id then
    -- trace start 语义：membership 缺失时创建（调用方可回读 result.root_trace_id）。
    local st = self:start_trace(snapshot, opts)
    if not st.ok then
      return { added = 0, skipped = 0, errors = { { error = st.error } }, total_candidates = 0 }
    end
    trace_id = st.root_trace_id
    membership = membership or st.membership
  end
  local result = trace_mod.backfill_chat(self:history_dir(), trace_id, snapshot, { membership = membership })
  result.root_trace_id = trace_id
  self:_emit_trace_event("trace.backfilled", { root_trace_id = trace_id, result = result })
  return result
end

--- record_turn：记录一个可见 natural turn（auto-save 接线在 W4 调用）。
--- 不可见消息 / 无 trace membership（untracked，含 unsavable）会话返回
--- {appended=false, skipped=true}，零写入。
---@param snapshot table 带 trace 的快照（trace.id + trace.membership）
---@param msg table 消息
---@param index integer 消息下标
---@param opts? {error?: boolean, status?: string, reason?: string}
---@return table result trace_mod.append_event 结果或 {appended=false, skipped=true}
function Service:record_turn(snapshot, msg, index, opts)
  opts = opts or {}
  if type(snapshot) ~= "table" or type(msg) ~= "table" then
    return { appended = false, skipped = true }
  end
  local trace_id = type(snapshot.trace) == "table" and snapshot.trace.id or nil
  if not trace_id then
    return { appended = false, skipped = true } -- untracked：零写入
  end
  if not trace_mod.is_visible_conversation_message(msg) then
    return { appended = false, skipped = true } -- 非 manual turn
  end
  local membership = trace_mod.get_membership(snapshot) or trace_mod.create_root_membership(trace_id)
  local event = trace_mod.message_to_turn_event(trace_id, snapshot, membership, msg, index, {
    error = opts.error,
    status = opts.status,
    reason = opts.reason,
  })
  if not event then
    return { appended = false, skipped = true }
  end
  local res, err = trace_mod.append_event(self:history_dir(), trace_id, event)
  if not res then
    return { appended = false, skipped = true, error = tostring(err) }
  end
  if res.appended then
    self:_emit_trace_event("trace.turn_recorded", {
      root_trace_id = trace_id,
      event_id = res.event_id,
      kind = event.kind,
    })
  end
  return res
end

--- title：标题生成入口。
--- title_provider="first_user" -> ids.get_chat_title；"none" -> 原样返回；
--- "auto" -> should_generate + LLM 生成，失败回退 first_user。
--- GENERATION GUARD：应用结果时 snapshot.session_id + snapshot.generation 必须与
--- opts.expect 匹配（expect 表可由调用方在异步回调到达前更新，模拟会话前进），
--- 不匹配则拒绝应用/持久化（title-late-callback fixture）。
--- 应用时经 save 持久化（刷新时 runtime_state.title_refresh_count +1）。
---@param snapshot table
---@param opts {expect?: {session_id?: string, generation?: number, save_id?: string}, interim?: fun(string)}
---@return table result {ok=true, title=string, applied?, save_id?} | {ok=true, pending=true}
---  | {ok=true, title=string, skipped=true} | {ok=false, code=..., error=...}
function Service:title(snapshot, opts)
  opts = opts or {}
  local verr = self:_validate_snapshot(snapshot)
  if verr then
    return { ok = false, code = "invalid_snapshot", error = verr }
  end
  local mode = self.config.title_provider or "auto"
  if mode == "none" then
    return { ok = true, title = snapshot.title or nil }
  end
  if mode == "first_user" then
    return { ok = true, title = ids.get_chat_title(snapshot.messages) }
  end
  local chat_state = {
    title = snapshot.title or nil,
    messages = snapshot.messages,
    user_message_count = self.title_generator:_count_user_messages(snapshot.messages),
    title_refresh_count = (snapshot.runtime_state and snapshot.runtime_state.title_refresh_count) or 0,
  }
  local should, is_refresh = self.title_generator:should_generate(chat_state)
  if not should then
    return { ok = true, title = snapshot.title or nil, skipped = true }
  end
  local res = self.title_generator:generate(snapshot, {
    is_refresh = is_refresh,
    refresh_count = chat_state.title_refresh_count,
    interim = opts.interim,
    on_result = function(result)
      self:_apply_title_result(snapshot, result, is_refresh, opts)
    end,
  })
  if res.ok and res.title then
    return self:_apply_title_result(snapshot, res, is_refresh, opts)
  end
  if res.ok and res.pending then
    return { ok = true, pending = true }
  end
  -- 生成失败：回退 first_user。
  return { ok = true, title = ids.get_chat_title(snapshot.messages), fallback = "first_user", error = res.error }
end

--- 应用标题结果：generation 守卫 -> format_title hook -> save 持久化。
---@param snapshot table
---@param result table {ok: boolean, title?: string, error?: string}
---@param is_refresh boolean
---@param opts {expect?: {session_id?: string, generation?: number, save_id?: string}}
---@return table result
function Service:_apply_title_result(snapshot, result, is_refresh, opts)
  local expect = opts.expect or {}
  local gen_ok = true
  if expect.session_id ~= nil then
    gen_ok = gen_ok and (snapshot.session_id == expect.session_id)
  end
  if expect.generation ~= nil then
    gen_ok = gen_ok and (tonumber(snapshot.generation) == tonumber(expect.generation))
  end
  if expect.save_id ~= nil then
    gen_ok = gen_ok and (self:current_save_id(snapshot.session_id) == expect.save_id)
  end
  if not gen_ok then
    return {
      ok = false,
      code = "generation_mismatch",
      error = "title generation result refused: session/generation mismatch",
    }
  end
  if not result.ok or not result.title then
    return { ok = false, error = result.error or "title generation failed" }
  end
  local title = result.title
  local fmt = self.config.title_generation_opts and self.config.title_generation_opts.format_title
  if type(fmt) == "function" then
    title = fmt(title)
  end
  local next_snapshot = vim.deepcopy(snapshot)
  next_snapshot.title = title
  next_snapshot.runtime_state = vim.deepcopy(snapshot.runtime_state or {})
  if is_refresh then
    next_snapshot.runtime_state.title_refresh_count = (next_snapshot.runtime_state.title_refresh_count or 0) + 1
  end
  local res = self:save(next_snapshot)
  if not res.ok then
    return res
  end
  self:_emit_history_event("history.title_changed", {
    save_id = res.save_id,
    session_id = snapshot.session_id,
    title = title,
    is_refresh = is_refresh == true,
  })
  return { ok = true, title = title, applied = true, is_refresh = is_refresh, save_id = res.save_id }
end

--- auto_save 接线：订阅既有事件（response.completed / tool_batch.finished /
--- chat.soft_stop_completed / chat.closed）。handler 经注入的 save_fn/snapshot_provider
--- 取快照并保存；跳过 unsavable 绑定会话；generation 守卫由构造保证（快照携带
--- generation，storage 拒绝 stale）。返回 self 便于链式。
---@return table self
function Service:listen()
  if self._listening then
    return self
  end
  self._listening = true
  local bus = self.events
  for _, event in ipairs(AUTO_SAVE_EVENTS) do
    local handler = function(payload)
      self:_handle_auto_save_event(payload)
    end
    local off = bus.on(event, handler)
    self._listeners[#self._listeners + 1] = { event = event, off = off, handler = handler }
  end
  return self
end

--- 取消全部 auto_save 订阅。
---@return table self
function Service:dispose()
  for _, entry in ipairs(self._listeners) do
    pcall(entry.off)
  end
  self._listeners = {}
  self._listening = false
  return self
end

function Service:_handle_auto_save_event(payload)
  if not self.config.auto_save then
    return
  end
  payload = payload or {}
  local session_id = payload.session_id
  if type(session_id) ~= "string" or session_id == "" then
    return
  end
  local save_id = self:current_save_id(session_id)
  if save_id and ids.is_unsavable_save_id(save_id) then
    return -- unsavable 会话不自动保存
  end
  -- W4-B: the host sets `service.snapshot_provider` after construction (the
  -- assembly cannot know the host's views); fall back to the constructor
  -- injected save_fn for legacy callers.
  local provider = self.snapshot_provider or self.save_fn
  if not provider then
    return
  end
  local snapshot = provider(session_id, payload)
  if not snapshot then
    return
  end
  local res = self:save(snapshot)
  -- W4 补 history.save_failed 事件；此处保留最近错误供诊断。
  self._last_auto_save_error = res.ok and nil or res
end

M.Service = Service

return M
