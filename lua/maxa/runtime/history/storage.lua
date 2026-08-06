-- filepath: lua/maxa/runtime/history/storage.lua
--- Phase-4 session history storage layer (W1): atomic session/index persistence
--- with schema-v1 envelope, per-save_id generation guard, serialized index
--- read-modify-write, and deterministic index rebuild.
---
--- 存储根：`<project-root>/.maxa/history/`（index.json + chats/ + traces/）。
--- 绝不读写开发母仓库的 `.supermax/`；`Storage.new` 只接受带 `.maxa/` 标记的
--- 显式项目根（测试注入 fixture 项目根，见 tests/history/lib/fixture_project.lua）。
---
--- 原子写契约（specs runtime-fixture-contract §Session persistence）：
--- 1) 完整校验信封；2) 同目录临时文件 + flush/close + rename 原子提交会话文件；
--- 3) 同样方式原子更新 index；4) 会话提交成功但 index 更新失败 →
--- `{ok=false, code='index_stale', status='saved-index-stale', save_id=...}`，
--- 保留有效会话文件，`rebuild_index()` 提供确定性重建；5) 会话提交成功前绝不报 saved。
---
--- 并发：同会话按 `runtime_state.generation` 串行（stale generation 拒绝覆盖）；
--- 不同会话可交错保存；index 更新为串行队列语义——每次更新前从磁盘重读最新
--- index 再原子写回（read-modify-write），交错保存不丢条目（tests/history/
--- concurrent-save.lua 通过 inject.before_index_update 注入嵌套保存验证）。
---
--- 本模块校验使用模块内代码字符串（M.CODES.*），不扩展 schema.ERROR；
--- load/rebuild 路径的“类型化错误”用 schema.new_error(PERSISTENCE, ...) 承载，
--- cause 内含模块级 code 与 path。

local schema = require("maxa.runtime.schema")
local ids = require("maxa.runtime.history.ids")

local M = {}

--- 当前信封 schema 版本（target 契约起点；>1 一律 fail-closed）。
M.SCHEMA_VERSION = 1

--- 模块内错误码（save 结果 / 迁移结果使用；schema.ERROR 不扩展）。
M.CODES = {
  WRITE_FAILED = "write_failed",
  INDEX_STALE = "index_stale",
  INVALID_SAVE_ID = "invalid_save_id",
  CORRUPT = "corrupt",
  GENERATION_CONFLICT = "generation_conflict",
}

--- 项目标记目录：镜像 config.STATE_DIR（".maxa"）。Storage 只接受显式 root，
--- 因此不依赖 config 模块；标记用于防止把 history 写到任意目录。
local STATE_DIR = ".maxa"

--- 构造类型化错误对象（模块内 code 放入 cause）。
local function typed_error(history_code, message, cause)
  local c = cause or {}
  c.history_code = history_code
  return schema.new_error(schema.ERROR.PERSISTENCE, message, c)
end

--- 校验 v1 信封结构。通过返回 nil；失败返回错误字符串。
---@param env any
---@return string|nil err
function M.validate_envelope(env)
  if type(env) ~= "table" then
    return "envelope must be a table"
  end
  if env.schema_version ~= M.SCHEMA_VERSION then
    return "schema_version must be " .. tostring(M.SCHEMA_VERSION)
  end
  if type(env.save_id) ~= "string" or env.save_id == "" or env.save_id:match("[/\\]") then
    return "save_id must be a non-empty path-safe string (no / or \\)"
  end
  for _, field in ipairs({ "session_id", "project_id", "provider_id", "protocol", "model" }) do
    if type(env[field]) ~= "string" then
      return field .. " must be a string"
    end
  end
  if env.parent_session_id ~= nil and type(env.parent_session_id) ~= "string" then
    return "parent_session_id must be a string or nil"
  end
  if env.title ~= nil and type(env.title) ~= "string" then
    return "title must be a string or nil"
  end
  if type(env.created_at) ~= "number" then
    return "created_at must be a number"
  end
  if type(env.updated_at) ~= "number" then
    return "updated_at must be a number"
  end
  if type(env.messages) ~= "table" or not (vim.islist or vim.tbl_islist)(env.messages) then
    return "messages must be an array"
  end
  for i, msg in ipairs(env.messages) do
    if type(msg) ~= "table" then
      return ("messages[%d] must be a table"):format(i)
    end
  end
  if type(env.context_items) ~= "table" then
    return "context_items must be a table"
  end
  if type(env.runtime_state) ~= "table" then
    return "runtime_state must be a table"
  end
  if type(env.trace) ~= "table" then
    return "trace must be a table"
  end
  if env.trace.id ~= nil and type(env.trace.id) ~= "string" then
    return "trace.id must be a string or nil"
  end
  if type(env.trace.membership) ~= "table" then
    return "trace.membership must be a table"
  end
  if type(env.status_snapshot) ~= "table" then
    return "status_snapshot must be a table"
  end
  return nil
end

--- 统计消息的字符串内容字符数（content 字符串或 content-parts 中的 text/content 字段）。
--- text part 形状为 `{ type="text", text=... }`（conversation.text_part）。
---@param msg table
---@return integer
local function count_message_chars(msg)
  local total = 0
  local content = msg.content
  if type(content) == "string" then
    total = total + #content
  elseif type(content) == "table" then
    for _, part in ipairs(content) do
      if type(part) == "table" then
        for _, field in ipairs({ "text", "content" }) do
          if type(part[field]) == "string" then
            total = total + #part[field]
          end
        end
      end
    end
  end
  return total
end

--- 由信封生成 index 条目（index 是派生查找结构，可重建，非内容权威）。
---@param env table v1 envelope
---@return table entry
local function make_index_entry(env)
  local message_count = #(env.messages or {})
  local total_chars = 0
  for _, msg in ipairs(env.messages or {}) do
    total_chars = total_chars + count_message_chars(msg)
  end
  local runtime_state = env.runtime_state or {}
  return {
    save_id = env.save_id,
    title = env.title,
    updated_at = env.updated_at,
    model = env.model,
    provider_id = env.provider_id,
    protocol = env.protocol,
    message_count = message_count,
    token_estimate = math.floor(total_chars / 4),
    cwd = runtime_state.cwd,
    project_root = runtime_state.project_root,
    compact_protected_prefix_count = runtime_state.compact_protected_prefix_count or 0,
    session_id = env.session_id,
    parent_session_id = env.parent_session_id,
  }
end

--- 读取 chat 文件原始内容。
---@param path string
---@return string|nil body
---@return string|nil err
local function read_file(path)
  if vim.fn.filereadable(path) == 0 then
    return nil, "file not found: " .. path
  end
  local fh, oerr = io.open(path, "rb")
  if not fh then
    return nil, "cannot open: " .. tostring(oerr)
  end
  local body = fh:read("*a")
  fh:close()
  return body, nil
end

--- 读取并解码 JSON（null -> nil，兼容 luanil 语义）。
---@param path string
---@return any|nil data
---@return string|nil err
local function read_json(path)
  local body, rerr = read_file(path)
  if not body then
    return nil, rerr
  end
  local ok, data = pcall(vim.json.decode, body, { luanil = { object = true, array = true } })
  if not ok or type(data) ~= "table" then
    return nil, "JSON parse failed: " .. tostring(data)
  end
  return data, nil
end

---@class HistoryStorage
---@field root string
---@field history_dir string
---@field index_path string
---@field chats_dir string
---@field traces_dir string
---@field expiration_days number
---@field inject table|nil
local Storage = {}

--- 构造存储。root 必须为带 `.maxa/` 标记的显式项目根。
---@param opts {root: string, expiration_days?: number, inject?: table}
---@return HistoryStorage
function M.new(opts)
  opts = opts or {}
  assert(type(opts.root) == "string" and opts.root ~= "", "history.storage: root is required")
  local root = vim.fn.fnamemodify(opts.root, ":p"):gsub("/+$", "")
  if vim.fn.isdirectory(root .. "/" .. STATE_DIR) == 0 then
    error("history.storage: root has no .maxa/ marker: " .. root, 0)
  end
  local self = setmetatable({}, { __index = Storage })
  self.root = root
  self.history_dir = root .. "/" .. STATE_DIR .. "/history"
  self.index_path = self.history_dir .. "/index.json"
  self.chats_dir = self.history_dir .. "/chats"
  self.traces_dir = self.history_dir .. "/traces"
  self.expiration_days = opts.expiration_days or 0
  self.inject = opts.inject
  self:_ensure_dirs()
  self:clean_expired_chats()
  return self
end

--- 确保 history 目录树存在（index 文件惰性创建，构造期不写文件）。
function Storage:_ensure_dirs()
  for _, dir in ipairs({ self.history_dir, self.chats_dir, self.traces_dir }) do
    if vim.fn.isdirectory(dir) == 0 then
      vim.fn.mkdir(dir, "p")
    end
  end
end

--- 原子写：同目录临时文件写入后 rename 落位；保证不出现部分目标文件。
--- 注入钩子（测试用）：`inject.fail_atomic_write_for[path]` 永久失败指定路径；
--- `inject.fail_next_write = N` 使接下来 N 次原子写失败。
---@param path string
---@param text string
---@return boolean ok
---@return string|nil err
function Storage:atomic_write(path, text)
  local inj = self.inject
  if inj then
    if inj.fail_atomic_write_for and inj.fail_atomic_write_for[path] then
      return nil, "injected atomic-write failure for " .. path
    end
    if type(inj.fail_next_write) == "number" and inj.fail_next_write > 0 then
      inj.fail_next_write = inj.fail_next_write - 1
      return nil, "injected next-write failure for " .. path
    end
  end
  local parent = vim.fn.fnamemodify(path, ":h")
  if vim.fn.isdirectory(parent) == 0 then
    vim.fn.mkdir(parent, "p")
  end
  local tmp = parent .. "/." .. vim.fn.fnamemodify(path, ":t") .. ".tmp." .. tostring(vim.loop.hrtime())
  local fh, oerr = io.open(tmp, "wb")
  if not fh then
    return nil, "atomic_write: open temp failed: " .. tostring(oerr)
  end
  local wok, werr = fh:write(text)
  fh:close()
  if not wok then
    os.remove(tmp)
    return nil, "atomic_write: write temp failed: " .. tostring(werr)
  end
  local rok, rerr = os.rename(tmp, path)
  if not rok then
    os.remove(tmp)
    return nil, "atomic_write: rename failed: " .. tostring(rerr)
  end
  return true, nil
end

--- 读取 index（每次更新前从磁盘重读；缺失 = 空表，损坏 = 错误）。
---@return table|nil index
---@return string|nil err
function Storage:_read_index()
  local data, err = read_json(self.index_path)
  if data == nil and err and err:match("^file not found") then
    return {}, nil
  end
  if not data then
    return nil, "index unreadable: " .. tostring(err)
  end
  return data, nil
end

--- 串行索引更新（read-modify-write）：重读最新 index -> 合并条目 -> 原子写回。
---@param env table v1 envelope
---@return boolean ok
---@return string|nil err
function Storage:_update_index(env)
  local index, rerr = self:_read_index()
  if not index then
    return nil, rerr
  end
  index[env.save_id] = make_index_entry(env)
  return self:atomic_write(self.index_path, vim.json.encode(index))
end

--- 保存会话：校验 -> generation 守卫 -> 原子提交会话文件 -> 原子更新 index。
--- 契约：会话提交成功前不报 saved；会话成功但 index 失败报 saved-index-stale。
---@param env table v1 envelope（messages 为不透明数组，按原样持久化）
---@return {ok: boolean, status?: string, save_id?: string, code?: string, error?: string, ...}
function Storage:save(env)
  local verr = M.validate_envelope(env)
  if verr then
    return { ok = false, code = M.CODES.INVALID_SAVE_ID, error = verr }
  end

  local incoming_gen = tonumber(env.runtime_state and env.runtime_state.generation) or 0
  local chat_path = self.chats_dir .. "/" .. env.save_id .. ".json"
  local durable, derr = read_json(chat_path)
  local durable_gen = 0
  if durable and type(durable.runtime_state) == "table" then
    durable_gen = tonumber(durable.runtime_state.generation) or 0
  end
  if incoming_gen < durable_gen then
    return {
      ok = false,
      code = M.CODES.GENERATION_CONFLICT,
      error = "stale generation: incoming " .. tostring(incoming_gen) .. " < durable " .. tostring(durable_gen),
      save_id = env.save_id,
      generation = incoming_gen,
      durable_generation = durable_gen,
    }
  end

  local okw, werr = self:atomic_write(chat_path, vim.json.encode(env))
  if not okw then
    return {
      ok = false,
      code = M.CODES.WRITE_FAILED,
      status = "write_failed",
      error = tostring(werr),
      save_id = env.save_id,
    }
  end

  -- 会话文件已提交；index 更新前注入点（并发测试用，单线程下模拟交错保存）。
  if self.inject and type(self.inject.before_index_update) == "function" then
    pcall(self.inject.before_index_update, self, env.save_id)
  end

  local oki, ierr = self:_update_index(env)
  if not oki then
    return {
      ok = false,
      code = M.CODES.INDEX_STALE,
      status = "saved-index-stale",
      error = tostring(ierr),
      save_id = env.save_id,
    }
  end

  return { ok = true, status = "saved", save_id = env.save_id }
end

--- 加载会话信封。缺失返回 (nil, nil)；损坏/非法返回 (nil, 类型化错误)。
---@param save_id string
---@return table|nil envelope
---@return table|nil err
function Storage:load_chat(save_id)
  if type(save_id) ~= "string" or save_id == "" or save_id:match("[/\\]") then
    return nil, typed_error(M.CODES.INVALID_SAVE_ID, "load_chat: invalid save_id " .. tostring(save_id))
  end
  local path = self.chats_dir .. "/" .. save_id .. ".json"
  local data, rerr = read_json(path)
  if not data then
    if rerr and rerr:match("^file not found") then
      return nil, nil
    end
    return nil, typed_error(M.CODES.CORRUPT, "load_chat: " .. tostring(rerr), { path = path })
  end
  local verr = M.validate_envelope(data)
  if verr then
    return nil, typed_error(M.CODES.CORRUPT, "load_chat: invalid envelope " .. path .. ": " .. verr, { path = path })
  end
  return data, nil
end

--- 读取 index 条目映射（缺失 = {}；损坏 = {} 且不抛错，可经 rebuild_index 修复）。
---@param filter_fn? fun(entry: table): boolean
---@return table<string, table> index map save_id -> entry
function Storage:get_chats(filter_fn)
  local data, _ = read_json(self.index_path)
  local all = data or {}
  if not filter_fn then
    return all
  end
  local filtered = {}
  for id, entry in pairs(all) do
    if filter_fn(entry) then
      filtered[id] = entry
    end
  end
  return filtered
end

--- 最近更新的会话（按 index updated_at）。
---@param filter_fn? fun(entry: table): boolean
---@return table|nil envelope
---@return table|nil err
function Storage:get_last_chat(filter_fn)
  local index = self:get_chats(filter_fn)
  local most_recent, most_recent_time = nil, -1
  for id, entry in pairs(index) do
    local t = entry.updated_at
    if type(t) == "number" and t > most_recent_time then
      most_recent, most_recent_time = id, t
    end
  end
  if not most_recent then
    return nil, nil
  end
  return self:load_chat(most_recent)
end

--- 删除会话（会话文件 + index 条目）。
---@param save_id string
---@return boolean
function Storage:delete_chat(save_id)
  if type(save_id) ~= "string" or save_id == "" or save_id:match("[/\\]") then
    return false
  end
  local path = self.chats_dir .. "/" .. save_id .. ".json"
  if vim.fn.filereadable(path) == 1 then
    local ok, _ = os.remove(path)
    if not ok then
      return false
    end
  end
  local index, rerr = self:_read_index()
  if not index then
    return false
  end
  if index[save_id] ~= nil then
    index[save_id] = nil
    local okw, _ = self:atomic_write(self.index_path, vim.json.encode(index))
    if not okw then
      return false
    end
  end
  return true
end

--- 重命名会话标题：先更新 index，再更新会话信封 title + updated_at。
---@param save_id string
---@param new_title string
---@return boolean
function Storage:rename_chat(save_id, new_title)
  if type(save_id) ~= "string" or type(new_title) ~= "string" then
    return false
  end
  local index, rerr = self:_read_index()
  if not index or not index[save_id] then
    return false
  end
  local now = os.time()
  index[save_id].title = new_title
  index[save_id].updated_at = now
  local okw, _ = self:atomic_write(self.index_path, vim.json.encode(index))
  if not okw then
    return false
  end
  local env, lerr = self:load_chat(save_id)
  if env then
    env.title = new_title
    env.updated_at = now
    local okc, _ = self:atomic_write(self.chats_dir .. "/" .. save_id .. ".json", vim.json.encode(env))
    if not okc then
      return false
    end
  end
  return true
end

--- 复制会话为新 save_id（标题缺省 `<原标题> (1)`，重置 title_refresh_count）。
---@param original_id string
---@param new_title? string
---@return string|nil new_save_id
function Storage:duplicate_chat(original_id, new_title)
  local orig, lerr = self:load_chat(original_id)
  if not orig then
    return nil
  end
  local new_save_id = ids.generate_save_id({ history_dir = self.history_dir })
  if not new_title then
    new_title = (orig.title or "Untitled") .. " (1)"
  end
  local dup = vim.deepcopy(orig)
  dup.save_id = new_save_id
  dup.title = new_title
  dup.updated_at = os.time()
  dup.runtime_state = vim.deepcopy(orig.runtime_state or {})
  dup.runtime_state.title_refresh_count = 0
  local res = self:save(dup)
  if not res.ok then
    return nil
  end
  return new_save_id
end

--- 从有效会话文件确定性重建 index。损坏文件跳过并报告（绝不删除）。
---@return {rebuilt: integer, skipped: {save_id: string, path: string, reason: string}[], error?: string}
function Storage:rebuild_index()
  local files = vim.fn.glob(self.chats_dir .. "/*.json", false, true)
  table.sort(files)
  local index = {}
  local skipped = {}
  local rebuilt = 0
  for _, path in ipairs(files) do
    local save_id = path:match("([^/]+)%.json$")
    local env, lerr = self:load_chat(save_id)
    if not env then
      skipped[#skipped + 1] = {
        save_id = save_id or path,
        path = path,
        reason = (lerr and lerr.message) or "missing/unreadable",
      }
    else
      index[save_id] = make_index_entry(env)
      rebuilt = rebuilt + 1
    end
  end
  local okw, werr = self:atomic_write(self.index_path, vim.json.encode(index))
  local result = { rebuilt = rebuilt, skipped = skipped }
  if not okw then
    result.error = tostring(werr)
  end
  return result
end

--- 清理过期会话（updated_at < now - expiration_days*86400），构造时调用。
---@return integer removed
function Storage:clean_expired_chats()
  if self.expiration_days <= 0 then
    return 0
  end
  local index = self:get_chats()
  local threshold = os.time() - self.expiration_days * 86400
  local removed = 0
  for id, entry in pairs(index) do
    if type(entry.updated_at) == "number" and entry.updated_at < threshold then
      if self:delete_chat(id) then
        removed = removed + 1
      end
    end
  end
  return removed
end

--- 存储根路径（调试/宿主接线用）。
---@return string
function Storage:get_location()
  return self.history_dir
end

return M
