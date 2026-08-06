-- filepath: lua/maxa/runtime/history/trace.lua
--- Phase-4 session trace storage/query primitives (W3).
---
--- Trace artifacts are project-local runtime history files under
--- `<history_dir>/traces/<root_trace_id>/{manifest.json,events.jsonl,index.json,archives/}`.
--- 行为基线（只读参考，非依赖）：`util/mcphub/cc_history/session_trace.lua`
--- （v18.7.0 扩展证据，1139 行）。本模块按 maxa target 契约重新实现：
---   * 所有路径函数显式接收 `history_dir`（服务层传 `storage.history_dir`），
---     不读取全局配置；
---   * 持久化 meta key 使用 target 自己的 `META_KEY="maxa_trace"`
---     （不复用 legacy 扩展的 `cc_history_trace`）；
---   * membership 优先读写信封 `trace.membership`（W1 v1 信封契约），
---     `holder._meta[META_KEY]` 仅为旧式 holder 兼容；
---   * 本模块是纯存储/查询库：不 emit 任何 bus 事件、不依赖 orchestrator/
---     session 内部实现；事件投影由服务层（history/init.lua）在其 bus 上发出。
---
--- 核心语义（与证据对齐）：
---   * `append_event` 按 `dedupe_key` 去重；重复返回
---     {appended=false, skipped=true, duplicate=true, event_id=...}，不追加行；
---   * `rebuild_index` 从 events.jsonl 确定性重建
---     （event_count / dedupe_keys / events_by_id / spans / save_ids），
---     corrupt 行收集为错误，绝不致命；
---   * natural turn 仅记录可见 manual user / agent reply / agent error；
---     auto-submit/regenerate/工具回合/标记消息不算 manual turn；
---   * untracked（unsavable / 无 membership）会话零写入。
---
--- W4（compaction wave）：extract_compression_archive_turns /
--- archive_compression_range / append_compression_applied 已在本模块实现；
--- write_archive 与 read_trace(include_archives) 自 W3 起可用。

local ids = require("maxa.runtime.history.ids")

local M = {}

M.SCHEMA_VERSION = 1
M.META_KEY = "maxa_trace"
M.TRUNCATE_SUFFIX = "...[truncated]"
M.SUMMARY_CONTENT_LENGTH = 300

---@return number 当前时间（os.time() 秒）。
local function now()
  return os.time()
end

--- 路径安全的普通 id（无路径分隔符，非 "." / ".."）。
---@param value any
---@return boolean
local function is_plain_id(value)
  return type(value) == "string" and value ~= "" and not value:match("[/\\]") and value ~= "." and value ~= ".."
end

---@param path string
local function ensure_dir(path)
  if vim.fn.isdirectory(path) == 0 then
    vim.fn.mkdir(path, "p")
  end
end

---@param content string
---@return any|nil data
---@return string|nil err
local function safe_json_decode(content)
  local ok, data = pcall(vim.json.decode, content, { luanil = { object = true, array = true } })
  if ok then
    return data, nil
  end
  return nil, tostring(data)
end

--- 递归移除函数字段（JSON 编码前的消毒；对齐证据 remove_functions 语义）。
---@param value any
---@param seen table|nil
---@return any
local function sanitize(value, seen)
  if type(value) ~= "table" then
    return value
  end
  seen = seen or {}
  if seen[value] then
    return nil -- 循环引用防护
  end
  seen[value] = true
  local out = {}
  for k, v in pairs(value) do
    if type(k) ~= "function" and type(v) ~= "function" then
      out[k] = sanitize(v, seen)
    end
  end
  return out
end

---@param path string
---@return any|nil data
---@return string|nil err
local function read_json_optional(path)
  if vim.fn.filereadable(path) == 0 then
    return nil, nil
  end
  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok then
    return nil, tostring(lines)
  end
  local content = table.concat(lines or {}, "\n")
  if content == "" then
    return nil, "empty JSON file: " .. path
  end
  return safe_json_decode(content)
end

---@param path string
---@param data any
---@return {ok: boolean, error?: string}
local function write_json(path, data)
  local parent = vim.fn.fnamemodify(path, ":h")
  ensure_dir(parent)
  local ok_encode, encoded = pcall(vim.json.encode, sanitize(data))
  if not ok_encode then
    return { ok = false, error = "Failed to encode JSON: " .. tostring(encoded) }
  end
  local ok_write, write_err = pcall(vim.fn.writefile, { encoded }, path)
  if not ok_write then
    return { ok = false, error = "Failed to write file: " .. tostring(write_err) }
  end
  return { ok = true, error = nil }
end

---@param path string
---@return string[]|nil lines
---@return string|nil err
local function read_lines(path)
  if vim.fn.filereadable(path) == 0 then
    return {}, nil
  end
  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok then
    return nil, tostring(lines)
  end
  return lines or {}, nil
end

---@param path string
---@param line string
---@return boolean ok
---@return string|nil err
local function append_line(path, line)
  local ok, err = pcall(vim.fn.writefile, { line }, path, "a")
  if not ok then
    return false, tostring(err)
  end
  return true, nil
end

--- 消息内容归一：nil -> ""；string 原样；table 取 .content 字符串，否则 JSON。
---@param value any
---@return string
local function normalize_content(value)
  if value == nil or value == vim.NIL then
    return ""
  end
  if type(value) == "string" then
    return value
  end
  if type(value) == "table" then
    if type(value.content) == "string" then
      return value.content
    end
    local ok, encoded = pcall(vim.json.encode, value)
    if ok and type(encoded) == "string" then
      return encoded
    end
  end
  return tostring(value)
end

--- 截断内容（summary 模式）。@param max_length integer|nil
local function truncate_content(content, max_length)
  content = normalize_content(content)
  max_length = max_length or M.SUMMARY_CONTENT_LENGTH
  if #content <= max_length then
    return content
  end
  return content:sub(1, math.max(0, max_length - #M.TRUNCATE_SUFFIX)) .. M.TRUNCATE_SUFFIX
end

--- 稳定内容哈希（sha256）：字符串原样哈希；表先 JSON 编码。
---@param value any
---@return string
function M.hash(value)
  local text
  if type(value) == "string" then
    text = value
  else
    local ok, encoded = pcall(vim.json.encode, value)
    text = ok and encoded or tostring(value)
  end
  return vim.fn.sha256(text or "")
end

--- 生成事件 id：`<prefix>_<ts>_<hrtime 尾 10 位>`。
---@param prefix? string
---@return string
function M.new_event_id(prefix)
  prefix = prefix or "evt"
  local uv = vim.uv or vim.loop
  local hr = uv and uv.hrtime and tostring(uv.hrtime()) or tostring(math.random(1000000000))
  return string.format("%s_%d_%s", prefix, now(), hr:sub(-10))
end

--- 生成 span id：`span_<role>_<hash 前 16 位>`。
---@param role? string
---@return string
function M.new_span_id(role)
  role = tostring(role or "span"):gsub("[^%w_-]", "_")
  return string.format(
    "span_%s_%s",
    role,
    M.hash(tostring(now()) .. ":" .. tostring(math.random()) .. ":" .. M.new_event_id("nonce")):sub(1, 16)
  )
end

--- 校验 root_trace_id：非空、路径安全（无 / 或 \\，非 "." / ".."）。
---@param root_trace_id any
---@return string|nil id
---@return string|nil err
function M.validate_trace_id(root_trace_id)
  if not is_plain_id(root_trace_id) then
    return nil, "root_trace_id must be a non-empty path-safe save_id"
  end
  return root_trace_id, nil
end

--- traces 根目录。@param history_dir string
function M.traces_dir(history_dir)
  return history_dir .. "/traces"
end

--- 单个 trace 目录。@param history_dir string @param root_trace_id string
---@return string|nil dir
---@return string|nil err
function M.get_trace_dir(history_dir, root_trace_id)
  local id, err = M.validate_trace_id(root_trace_id)
  if not id then
    return nil, err
  end
  return M.traces_dir(history_dir) .. "/" .. id, nil
end

--- trace 文件路径表。@param history_dir string @param root_trace_id string
---@return table|nil paths {trace_dir, manifest, events, index, archives_dir}
---@return string|nil err
function M.paths(history_dir, root_trace_id)
  local trace_dir, err = M.get_trace_dir(history_dir, root_trace_id)
  if not trace_dir then
    return nil, err
  end
  return {
    trace_dir = trace_dir,
    manifest = trace_dir .. "/manifest.json",
    events = trace_dir .. "/events.jsonl",
    index = trace_dir .. "/index.json",
    archives_dir = trace_dir .. "/archives",
  },
    nil
end

--- 确保 trace 目录结构存在（trace_dir + archives/ + 空 events.jsonl）。
---@param history_dir string
---@param root_trace_id string
---@return table|nil paths
---@return string|nil err
local function ensure_trace_dir(history_dir, root_trace_id)
  local paths, err = M.paths(history_dir, root_trace_id)
  if not paths then
    return nil, err
  end
  ensure_dir(paths.trace_dir)
  ensure_dir(paths.archives_dir)
  if vim.fn.filereadable(paths.events) == 0 then
    local ok, write_err = pcall(vim.fn.writefile, {}, paths.events)
    if not ok then
      return nil, tostring(write_err)
    end
  end
  return paths, nil
end

--- trace 是否存在（manifest + events 均可读）。
---@param history_dir string
---@param root_trace_id string
---@return boolean
function M.trace_exists(history_dir, root_trace_id)
  local paths = M.paths(history_dir, root_trace_id)
  return type(paths) == "table" and vim.fn.filereadable(paths.manifest) == 1 and vim.fn.filereadable(paths.events) == 1
end

--- 默认 manifest。@param root_trace_id string @param opts? table
---@return table
function M.default_manifest(root_trace_id, opts)
  opts = opts or {}
  return {
    schema_version = M.SCHEMA_VERSION,
    root_trace_id = root_trace_id,
    root_save_id = opts.root_save_id or root_trace_id,
    root_title = opts.root_title,
    status = opts.status or "active",
    created_at = opts.created_at or now(),
    updated_at = opts.updated_at or now(),
    source = opts.source or "trace_start",
  }
end

---@param history_dir string @param root_trace_id string
---@return table|nil manifest
---@return string|nil err
function M.read_manifest(history_dir, root_trace_id)
  local paths, err = M.paths(history_dir, root_trace_id)
  if not paths then
    return nil, err
  end
  return read_json_optional(paths.manifest)
end

---@param history_dir string @param root_trace_id string @param manifest table
---@return boolean ok
---@return string|nil err
function M.write_manifest(history_dir, root_trace_id, manifest)
  local paths, err = ensure_trace_dir(history_dir, root_trace_id)
  if not paths then
    return false, err
  end
  manifest = vim.deepcopy(manifest or {})
  manifest.schema_version = manifest.schema_version or M.SCHEMA_VERSION
  manifest.root_trace_id = manifest.root_trace_id or root_trace_id
  manifest.root_save_id = manifest.root_save_id or root_trace_id
  manifest.updated_at = manifest.updated_at or now()
  local result = write_json(paths.manifest, manifest)
  return result.ok, result.error
end

--- 已存在则返回现有 manifest，否则创建默认 manifest。
---@param history_dir string @param root_trace_id string @param opts? table
---@return table|nil manifest
---@return string|nil err
function M.ensure_manifest(history_dir, root_trace_id, opts)
  local existing, err = M.read_manifest(history_dir, root_trace_id)
  if err then
    return nil, err
  end
  if existing then
    return existing, nil
  end
  local manifest = M.default_manifest(root_trace_id, opts)
  local ok, write_err = M.write_manifest(history_dir, root_trace_id, manifest)
  if not ok then
    return nil, write_err
  end
  return manifest, nil
end

--- 合并 patch 更新 manifest（updated_at 刷新）。
---@param history_dir string @param root_trace_id string @param patch table
---@return table|nil manifest
---@return string|nil err
function M.update_manifest(history_dir, root_trace_id, patch)
  patch = patch or {}
  local manifest, err = M.ensure_manifest(history_dir, root_trace_id, patch)
  if not manifest then
    return nil, err
  end
  for k, v in pairs(patch) do
    manifest[k] = v
  end
  manifest.root_trace_id = manifest.root_trace_id or root_trace_id
  manifest.root_save_id = manifest.root_save_id or root_trace_id
  manifest.updated_at = now()
  local ok, write_err = M.write_manifest(history_dir, root_trace_id, manifest)
  if not ok then
    return nil, write_err
  end
  return manifest, nil
end

--- 空 index。@param root_trace_id string
---@return table
local function empty_index(root_trace_id)
  return {
    schema_version = M.SCHEMA_VERSION,
    root_trace_id = root_trace_id,
    updated_at = now(),
    event_count = 0,
    dedupe_keys = {},
    events_by_id = {},
    spans = {},
    save_ids = {},
  }
end

---@param history_dir string @param root_trace_id string
---@return table|nil index
---@return string|nil err
function M.read_index(history_dir, root_trace_id)
  local paths, err = M.paths(history_dir, root_trace_id)
  if not paths then
    return nil, err
  end
  local index, read_err = read_json_optional(paths.index)
  if read_err then
    return nil, read_err
  end
  return index or empty_index(root_trace_id), nil
end

---@param history_dir string @param root_trace_id string @param index table
---@return boolean ok
---@return string|nil err
function M.write_index(history_dir, root_trace_id, index)
  local paths, err = ensure_trace_dir(history_dir, root_trace_id)
  if not paths then
    return false, err
  end
  index = index or empty_index(root_trace_id)
  index.schema_version = index.schema_version or M.SCHEMA_VERSION
  index.root_trace_id = index.root_trace_id or root_trace_id
  index.updated_at = now()
  local result = write_json(paths.index, index)
  return result.ok, result.error
end

--- 读取事件列表（JSONL）。corrupt 行收集到 errors，绝不致命。
---@param history_dir string @param root_trace_id string
---@return table|nil events
---@return string|nil err
---@return table|nil errors {line: integer, error: string}[]
function M.read_events(history_dir, root_trace_id)
  local paths, err = M.paths(history_dir, root_trace_id)
  if not paths then
    return nil, err
  end
  local lines, read_err = read_lines(paths.events)
  if not lines then
    return nil, read_err
  end
  local events = {}
  local errors = {}
  for line_no, line in ipairs(lines) do
    if line and line ~= "" then
      local event, decode_err = safe_json_decode(line)
      if type(event) == "table" then
        table.insert(events, event)
      else
        table.insert(errors, { line = line_no, error = decode_err or "invalid JSONL event" })
      end
    end
  end
  return events, nil, errors
end

--- 从 events.jsonl 确定性重建 index 并写盘。
---@param history_dir string @param root_trace_id string
---@return table|nil index
---@return string|nil err
function M.rebuild_index(history_dir, root_trace_id)
  local events, err = M.read_events(history_dir, root_trace_id)
  if not events then
    return nil, err
  end
  local index = empty_index(root_trace_id)
  for _, event in ipairs(events) do
    index.event_count = index.event_count + 1
    if event.event_id then
      index.events_by_id[event.event_id] = {
        kind = event.kind,
        created_at = event.created_at,
        dedupe_key = event.dedupe_key,
      }
    end
    if event.dedupe_key then
      index.dedupe_keys[event.dedupe_key] = event.event_id or true
    end
    if event.span_id then
      index.spans[event.span_id] = index.spans[event.span_id]
        or {
          span_id = event.span_id,
          parent_span_id = event.parent_span_id,
          role = event.session and event.session.role or nil,
          event_count = 0,
        }
      index.spans[event.span_id].event_count = (index.spans[event.span_id].event_count or 0) + 1
    end
    local save_id = event.session and event.session.save_id
    if save_id then
      index.save_ids[save_id] = event.span_id or true
    end
  end
  local ok, write_err = M.write_index(history_dir, root_trace_id, index)
  if not ok then
    return nil, write_err
  end
  return index, nil
end

--- 追加事件：dedupe_key 去重 -> 自动补字段 -> 追加 JSONL -> 更新 manifest -> 重建 index。
--- 重复返回 {appended=false, skipped=true, duplicate=true, event_id=已有事件 id, event=入参}。
---@param history_dir string
---@param root_trace_id string
---@param event table
---@return table|nil result {appended: boolean, skipped: boolean, duplicate: boolean, event_id?: string, event?: table}
---@return string|nil err
function M.append_event(history_dir, root_trace_id, event)
  if type(event) ~= "table" then
    return nil, "event must be a table"
  end
  local paths, err = ensure_trace_dir(history_dir, root_trace_id)
  if not paths then
    return nil, err
  end

  local index, index_err = M.read_index(history_dir, root_trace_id)
  if not index then
    index, index_err = M.rebuild_index(history_dir, root_trace_id)
  end
  if not index then
    return nil, index_err
  end

  if event.dedupe_key and index.dedupe_keys and index.dedupe_keys[event.dedupe_key] then
    return {
      appended = false,
      skipped = true,
      duplicate = true,
      event_id = index.dedupe_keys[event.dedupe_key],
      event = event,
    },
      nil
  end

  event = vim.deepcopy(event)
  event.schema_version = event.schema_version or M.SCHEMA_VERSION
  event.root_trace_id = event.root_trace_id or root_trace_id
  event.event_id = event.event_id or M.new_event_id("evt")
  event.created_at = event.created_at or now()
  event.dedupe_key = event.dedupe_key or ("event:" .. event.kind .. ":" .. M.hash(event))

  local encoded = vim.json.encode(sanitize(event))
  local ok, append_err = append_line(paths.events, encoded)
  if not ok then
    return nil, append_err
  end

  M.update_manifest(history_dir, root_trace_id, {})
  M.rebuild_index(history_dir, root_trace_id)

  return {
    appended = true,
    skipped = false,
    duplicate = false,
    event_id = event.event_id,
    event = event,
  },
    nil
end

--- 写压缩归档文件 `archives/<event_id>.json`（W4 compaction 使用；本 wave 提供能力）。
---@param history_dir string @param root_trace_id string @param archive table
---@return table|nil result {event_id: string, path: string, archive: table}
---@return string|nil err
function M.write_archive(history_dir, root_trace_id, archive)
  archive = vim.deepcopy(archive or {})
  archive.schema_version = archive.schema_version or M.SCHEMA_VERSION
  archive.root_trace_id = archive.root_trace_id or root_trace_id
  local event_id = archive.event_id or M.new_event_id("archive")
  archive.event_id = event_id
  local paths, err = ensure_trace_dir(history_dir, root_trace_id)
  if not paths then
    return nil, err
  end
  local path = paths.archives_dir .. "/" .. event_id .. ".json"
  local result = write_json(path, archive)
  if not result.ok then
    return nil, result.error
  end
  return { event_id = event_id, path = path, archive = archive }, nil
end

--- 读取 holder 的 trace membership：
--- 优先信封 `holder.trace.membership`；兼容旧式 `holder._meta[META_KEY]`。
---@param holder table|nil
---@return table|nil membership
function M.get_membership(holder)
  if type(holder) ~= "table" then
    return nil
  end
  if type(holder.trace) == "table" and type(holder.trace.membership) == "table" then
    return holder.trace.membership
  end
  if type(holder._meta) == "table" and type(holder._meta[M.META_KEY]) == "table" then
    return holder._meta[M.META_KEY]
  end
  return nil
end

--- 写入 holder 的 trace membership：信封形状（有 .trace 字段）写
--- `holder.trace = {id=..., membership=...}`；否则写 `holder._meta[META_KEY]`。
--- 自动补 root_save_id/span_id/session_role/started_at/active 缺省。
---@param holder table
---@param membership table
---@return table|nil membership
---@return string|nil err
function M.set_membership(holder, membership)
  if type(holder) ~= "table" then
    return nil, "holder must be a table"
  end
  if type(membership) ~= "table" then
    return nil, "membership must be a table"
  end
  membership = vim.deepcopy(membership)
  membership.root_trace_id = membership.root_trace_id or membership.root_save_id
  if not membership.root_trace_id then
    return nil, "membership.root_trace_id is required"
  end
  membership.root_save_id = membership.root_save_id or membership.root_trace_id
  membership.span_id = membership.span_id or M.new_span_id(membership.session_role or "session")
  membership.session_role = membership.session_role or "root"
  membership.started_at = membership.started_at or now()
  if membership.active == nil then
    membership.active = true
  end
  if type(holder.trace) == "table" then
    holder.trace = { id = membership.root_trace_id, membership = membership }
  else
    holder._meta = holder._meta or {}
    holder._meta[M.META_KEY] = membership
  end
  return membership, nil
end

--- 复制 membership 到 target（fork 语义）：new_span=true 时生成新 span，
--- parent_span_id 指向源 span。@param source table @param target table @param opts? table
---@return table|nil membership
---@return string|nil err
function M.copy_membership(source, target, opts)
  opts = opts or {}
  local source_membership = M.get_membership(source)
  if not source_membership then
    return nil, "source has no trace membership"
  end
  local membership = vim.deepcopy(source_membership)
  if opts.new_span then
    membership.parent_span_id = opts.parent_span_id or source_membership.span_id
    membership.span_id = opts.span_id or M.new_span_id(opts.session_role or source_membership.session_role or "session")
    membership.started_at = now()
  end
  if opts.session_role then
    membership.session_role = opts.session_role
  end
  if opts.source_event_id ~= nil then
    membership.source_event_id = opts.source_event_id
  end
  return M.set_membership(target, membership)
end

--- 创建根 membership。@param root_trace_id string @param opts? table
---@return table
function M.create_root_membership(root_trace_id, opts)
  opts = opts or {}
  return {
    root_trace_id = root_trace_id,
    root_save_id = opts.root_save_id or root_trace_id,
    span_id = opts.span_id or M.new_span_id("root"),
    parent_span_id = opts.parent_span_id,
    session_role = opts.session_role or "root",
    source_event_id = opts.source_event_id,
    started_at = opts.started_at or now(),
    active = opts.active ~= false,
  }
end

--- 会话摘要信息（事件 session 字段）。
---@param chat_or_data table|nil
---@param membership table|nil
---@return table {save_id: string|nil, temporary: boolean, role: string|nil}
local function session_info(chat_or_data, membership)
  membership = membership or M.get_membership(chat_or_data) or {}
  local save_id = chat_or_data and (chat_or_data.opts and chat_or_data.opts.save_id or chat_or_data.save_id or nil)
    or nil
  return {
    save_id = save_id,
    temporary = save_id and ids.is_unsavable_save_id(save_id) or false,
    role = membership.session_role,
  }
end

--- natural turn 去重 key：`turn:<save|span>:<index>:<role>:<hash(content)>`。
---@param save_id_or_span string|nil
---@param message_index integer|nil
---@param role string|nil
---@param content any
---@return string
function M.natural_turn_dedupe_key(save_id_or_span, message_index, role, content)
  return table.concat({
    "turn",
    tostring(save_id_or_span or "unknown"),
    tostring(message_index or "unknown"),
    tostring(role or "unknown"),
    M.hash(normalize_content(content)),
  }, ":")
end

--- 标记类消息不算 manual natural turn（对齐证据 IGNORED_NATURAL_TURN_TAGS）。
local IGNORED_NATURAL_TURN_TAGS = {
  system_prompt_from_config = true,
  rules = true,
  file = true,
  variable = true,
  compact_summary = true,
  collapse_summary = true,
  context_file = true,
  mcp_tools = true,
  mcp_docs = true,
  agent_boundary = true,
}

--- 消息是否携带工具负载（工具回合不算 manual turn）。
---@param msg table
---@return boolean
local function has_tool_payload(msg)
  return (msg.tools and (msg.tools.calls or msg.tools.call_id)) or msg.tool_calls or msg.tool_call_id
end

--- 可见对话消息判定（natural turn 记录的唯一入口）：
--- 排除 visible=false / context / inserted_from_fragment / IGNORED tags / tool payload；
--- 仅 user / llm|assistant 且无工具负载的消息可见。
---@param msg any
---@return boolean
local function is_visible_conversation_message(msg)
  if type(msg) ~= "table" then
    return false
  end
  if msg.opts and msg.opts.visible == false then
    return false
  end
  if msg.context then
    return false
  end
  local meta = type(msg._meta) == "table" and msg._meta or {}
  if meta.inserted_from_fragment then
    return false
  end
  if meta.tag and IGNORED_NATURAL_TURN_TAGS[meta.tag] then
    return false
  end
  if msg.role == "user" then
    return not has_tool_payload(msg)
  end
  if msg.role == "llm" or msg.role == "assistant" then
    return not has_tool_payload(msg)
  end
  return false
end

M.is_visible_conversation_message = is_visible_conversation_message
M.is_visible_natural_turn_message = is_visible_conversation_message

--- 消息 -> natural turn 事件（main_turn.user_prompt / agent_reply / agent_error）。
---@param root_trace_id string
---@param chat_or_data table|nil chat_data 形状（.messages / .opts.save_id 或 .save_id）
---@param membership table|nil
---@param msg table
---@param index integer 消息下标（message_index）
---@param opts? {error?: boolean, status?: string, reason?: string}
---@return table|nil event
function M.message_to_turn_event(root_trace_id, chat_or_data, membership, msg, index, opts)
  opts = opts or {}
  membership = membership or M.get_membership(chat_or_data) or M.create_root_membership(root_trace_id)
  local role = msg.role == "llm" and "assistant" or msg.role
  local kind
  if role == "user" then
    kind = "main_turn.user_prompt"
  elseif role == "assistant" then
    kind = opts.error and "main_turn.agent_error" or "main_turn.agent_reply"
  else
    return nil
  end
  local save_id = chat_or_data and chat_or_data.opts and chat_or_data.opts.save_id
    or chat_or_data and chat_or_data.save_id
    or root_trace_id
  local content = normalize_content(msg.content)
  return {
    schema_version = M.SCHEMA_VERSION,
    root_trace_id = root_trace_id,
    kind = kind,
    span_id = membership.span_id,
    parent_span_id = membership.parent_span_id,
    session = session_info(chat_or_data, membership),
    message = {
      role = role,
      content = content,
      message_index = index,
    },
    status = opts.status,
    reason = opts.reason,
    dedupe_key = M.natural_turn_dedupe_key(save_id or membership.span_id, index, role, content),
  }
end

--- 压缩归档消息的错误状态判定（对齐证据 trace_error_status 语义）：
--- assistant 消息 `_meta.status` 非空或 `_meta.kind == "main_turn.agent_error"`
--- 视为错误 turn。
---@param msg table
---@param meta table
---@return string|nil status
---@return string|nil reason
local function trace_error_status(msg, meta)
  meta = meta or {}
  local kind = meta.kind
  local status = meta.status
  if kind == "main_turn.agent_error" then
    return (type(status) == "string" and status ~= "" and status) or "error", meta.reason
  end
  if type(status) == "string" and status ~= "" then
    return status, meta.reason
  end
  return nil, nil
end

--- 从消息范围内提取可见对话 turns（压缩归档数据源）。
--- 仅统计可见 conversation 消息（is_visible_conversation_message）；
--- assistant 按 trace_error_status 判定 agent_error / agent_reply。
---@param messages table[]
---@param start_index? integer
---@param end_index? integer
---@return table[] turns {kind, role, content, message_index, status?, reason?}
---@return table counts {start_index, end_index, total_messages, turn_count, omitted_count}
function M.extract_compression_archive_turns(messages, start_index, end_index)
  local turns = {}
  local total = 0
  start_index = math.max(1, tonumber(start_index) or 1)
  end_index = math.min(#(messages or {}), tonumber(end_index) or #(messages or {}))
  for index = start_index, end_index do
    total = total + 1
    local msg = messages[index]
    if M.is_visible_conversation_message(msg) then
      local role = msg.role == "llm" and "assistant" or msg.role
      local meta = type(msg._meta) == "table" and msg._meta or {}
      local status, reason
      if role == "assistant" then
        status, reason = trace_error_status(msg, meta)
      end
      local kind
      if role == "user" then
        kind = "main_turn.user_prompt"
      elseif role == "assistant" then
        kind = status and "main_turn.agent_error" or "main_turn.agent_reply"
      end
      if kind then
        table.insert(turns, {
          kind = kind,
          role = role,
          content = normalize_content(msg.content),
          message_index = index,
          status = status,
          reason = reason,
        })
      end
    end
  end
  return turns,
    {
      start_index = start_index,
      end_index = end_index,
      total_messages = total,
      turn_count = #turns,
      omitted_count = math.max(0, total - #turns),
    }
end

--- 从压缩 source 提取 save_id。
---@param source table|nil
---@param fallback string|nil
---@return string|nil
local function source_save_id(source, fallback)
  if type(source) ~= "table" then
    return fallback
  end
  return source.save_id or fallback
end

--- 准备压缩 trace source 的 membership（无 membership = untracked）。
---@param source table|nil
---@return table|nil membership
local function prepare_compression_trace_source(source)
  if type(source) ~= "table" then
    return nil
  end
  return M.get_membership(source)
end

--- 压缩归档：写 archive JSON + 追加 `compression.archive_created` 事件。
--- 归档范围 [start_index, end_index] 必须是 1.. #messages 内合法闭区间；
--- 同一 dedupe_key（`archive:<span>:<save>:<start>:<end>:<hash>`）重复归档
--- 返回 duplicate 结果且不追加任何内容。untracked（无 membership）返回
--- {tracked=false}，零写入。
---@param history_dir string
---@param root_trace_id string
---@param source table {messages: table[], save_id?: string, source_type?: string,
---  trace?: {id?: string, membership?: table}}
---@param range {start_index: integer, end_index: integer, action?: string}
---@param opts? {tool_name?: string, mode?: string, action?: string, range_index?: integer, save_id?: string}
---@return table|nil result {tracked=true, event_id, path, archive, append_result,
---  appended, duplicate, turn_count, content_hash, dedupe_key} | {tracked=false}
---@return string|nil err
function M.archive_compression_range(history_dir, root_trace_id, source, range, opts)
  opts = opts or {}
  local membership = prepare_compression_trace_source(source)
  if not membership then
    return { tracked = false }, nil
  end
  range = range or {}
  local messages = (source and source.messages) or {}
  local start_index = tonumber(range.start_index)
  local end_index = tonumber(range.end_index)
  if not start_index or not end_index then
    return nil, "compression archive range requires start_index and end_index"
  end
  start_index = math.floor(start_index)
  end_index = math.floor(end_index)
  if start_index < 1 or end_index < start_index or end_index > #messages then
    return nil,
      string.format(
        "compression archive range [%s,%s] is outside message bounds 1..%d",
        tostring(range.start_index),
        tostring(range.end_index),
        #messages
      )
  end

  local root_id = root_trace_id or membership.root_trace_id
  local save_id = source_save_id(source, opts.save_id)
  local turns, counts = M.extract_compression_archive_turns(messages, start_index, end_index)
  local content_hash = M.hash({
    source_save_id = save_id,
    span_id = membership.span_id,
    range = { start_index = start_index, end_index = end_index },
    turns = turns,
  })
  local dedupe_key = table.concat({
    "archive",
    tostring(membership.span_id or "unknown"),
    tostring(save_id or "unsaved"),
    tostring(start_index),
    tostring(end_index),
    content_hash,
  }, ":")
  local event_id = "archive_" .. M.hash(dedupe_key):sub(1, 24)
  local archive = {
    schema_version = M.SCHEMA_VERSION,
    event_id = event_id,
    root_trace_id = root_id,
    source_save_id = save_id,
    span_id = membership.span_id,
    parent_span_id = membership.parent_span_id,
    session = session_info(source or { save_id = save_id }, membership),
    source = {
      type = source and source.source_type,
      save_id = save_id,
    },
    compression = {
      tool = opts.tool_name,
      mode = opts.mode,
      action = range.action or opts.action,
      range_index = opts.range_index,
    },
    range = {
      start_index = start_index,
      end_index = end_index,
      action = range.action,
    },
    turns = turns,
    counts = counts,
    content_hash = content_hash,
    dedupe_key = dedupe_key,
  }

  local archive_result, archive_err = M.write_archive(history_dir, root_id, archive)
  if not archive_result then
    return nil, archive_err
  end

  local event = {
    schema_version = M.SCHEMA_VERSION,
    event_id = event_id,
    root_trace_id = root_id,
    kind = "compression.archive_created",
    span_id = membership.span_id,
    parent_span_id = membership.parent_span_id,
    session = archive.session,
    source = archive.source,
    compression = archive.compression,
    range = archive.range,
    archive = {
      event_id = event_id,
      path = archive_result.path,
      turn_count = #turns,
      content_hash = content_hash,
    },
    counts = counts,
    dedupe_key = dedupe_key,
  }
  local append_result, append_err = M.append_event(history_dir, root_id, event)
  if not append_result then
    return nil, append_err
  end

  return {
    tracked = true,
    event_id = event_id,
    path = archive_result.path,
    archive = archive_result.archive,
    append_result = append_result,
    appended = append_result.appended == true,
    duplicate = append_result.duplicate == true,
    turn_count = #turns,
    content_hash = content_hash,
    dedupe_key = dedupe_key,
  },
    nil
end

--- 追加 `compression.applied` 事件（压缩已应用审计）。
--- dedupe_key = `compression.applied:<span>:<save>:<action|tool>:<hash>`。
---@param history_dir string
---@param root_trace_id string
---@param source table {messages?: table[], save_id?: string, source_type?: string,
---  trace?: {id?: string, membership?: table}}
---@param opts? {tool_name?: string, mode?: string, action?: string, source_save_id?: string,
---  new_save_id?: string, original_save_id?: string, pending?: boolean, stats?: table,
---  archives?: table[], save_id?: string}
---@return table|nil result append_event 结果 | {tracked=false}
---@return string|nil err
function M.append_compression_applied(history_dir, root_trace_id, source, opts)
  opts = opts or {}
  local membership = prepare_compression_trace_source(source)
  if not membership then
    return { tracked = false }, nil
  end
  local root_id = root_trace_id or membership.root_trace_id
  local save_id = source_save_id(source, opts.save_id)
  local archive_ids = {}
  for _, archive in ipairs(opts.archives or {}) do
    table.insert(archive_ids, archive.event_id or archive.dedupe_key or archive.content_hash)
  end
  local payload_hash = M.hash({
    archive_ids = archive_ids,
    action = opts.action,
    mode = opts.mode,
    source_save_id = save_id,
    new_save_id = opts.new_save_id,
    stats = opts.stats,
  })
  local dedupe_key = table.concat({
    "compression.applied",
    tostring(membership.span_id or "unknown"),
    tostring(save_id or "unsaved"),
    tostring(opts.action or opts.tool_name or "unknown"),
    payload_hash,
  }, ":")
  local event = {
    schema_version = M.SCHEMA_VERSION,
    root_trace_id = root_id,
    kind = "compression.applied",
    span_id = membership.span_id,
    parent_span_id = membership.parent_span_id,
    session = session_info(source or { save_id = save_id }, membership),
    compression = {
      tool = opts.tool_name,
      mode = opts.mode,
      action = opts.action,
      source_save_id = save_id,
      new_save_id = opts.new_save_id,
      original_save_id = opts.original_save_id,
      pending = opts.pending == true or nil,
      stats = opts.stats,
      archive_event_ids = archive_ids,
    },
    dedupe_key = dedupe_key,
  }
  return M.append_event(history_dir, root_id, event)
end

--- backfill：逐消息追加可见 natural turn + 一个 `trace.backfilled` summary 事件
--- （summary 自带 dedupe_key，重复 backfill 幂等——不加任何事件）。
---@param history_dir string
---@param root_trace_id string
---@param chat_or_data table|nil
---@param opts? {membership?: table}
---@return table result {added: integer, skipped: integer, errors: table[],
---  total_candidates: integer, backfill_event_added?: boolean, backfill_event_skipped?: boolean}
function M.backfill_chat(history_dir, root_trace_id, chat_or_data, opts)
  opts = opts or {}
  local membership = opts.membership or M.get_membership(chat_or_data) or M.create_root_membership(root_trace_id)
  local messages = chat_or_data and chat_or_data.messages or {}
  local result = { added = 0, skipped = 0, errors = {}, total_candidates = 0 }
  for index, msg in ipairs(messages) do
    if is_visible_conversation_message(msg) then
      local event = M.message_to_turn_event(root_trace_id, chat_or_data, membership, msg, index)
      if event then
        result.total_candidates = result.total_candidates + 1
        local append_result, err = M.append_event(history_dir, root_trace_id, event)
        if not append_result then
          table.insert(result.errors, { index = index, error = err })
        elseif append_result.appended then
          result.added = result.added + 1
        else
          result.skipped = result.skipped + 1
        end
      end
    end
  end

  local summary_key = table.concat({
    "trace.backfilled",
    tostring(root_trace_id),
    tostring(
      chat_or_data and chat_or_data.opts and chat_or_data.opts.save_id
        or chat_or_data and chat_or_data.save_id
        or root_trace_id
    ),
    tostring(#messages),
    M.hash(messages),
  }, ":")
  local summary_event = {
    schema_version = M.SCHEMA_VERSION,
    root_trace_id = root_trace_id,
    kind = "trace.backfilled",
    span_id = membership.span_id,
    parent_span_id = membership.parent_span_id,
    session = session_info(chat_or_data, membership),
    backfill = {
      message_count = #messages,
      added = result.added,
      skipped = result.skipped,
      total_candidates = result.total_candidates,
      error_count = #result.errors,
    },
    dedupe_key = summary_key,
  }
  local append_result, err = M.append_event(history_dir, root_trace_id, summary_event)
  if not append_result then
    table.insert(result.errors, { event = "trace.backfilled", error = err })
  elseif append_result.appended then
    result.backfill_event_added = true
  else
    result.backfill_event_skipped = true
  end

  return result
end

--- summary 模式事件瘦身：截断 message/result 内容，省略 params.messages。
---@param event table @param mode string
---@return table
local function summarize_event(event, mode)
  local out = vim.deepcopy(event)
  if mode == "summary" then
    if out.message and out.message.content then
      out.message.content = truncate_content(out.message.content)
      out.message.truncated = normalize_content(event.message.content) ~= out.message.content
    end
    if out.result and out.result.content then
      out.result.content = truncate_content(out.result.content)
    end
    if out.params and out.params.messages then
      out.params.messages = "[omitted in summary mode]"
    end
  end
  return out
end

--- 读取 trace（recorded）：summary/full + skip/take + parse_errors + 可选 archives。
---@param history_dir string
---@param root_trace_id string
---@param opts? {mode?: "summary"|"full", skip?: integer, take?: integer, include_archives?: boolean}
---@return table|nil result {source="recorded", root_trace_id, manifest, events, total_events,
---  returned_events, skip, take, mode, parse_errors, archives?}
---@return string|nil err
function M.read_trace(history_dir, root_trace_id, opts)
  opts = opts or {}
  local manifest, manifest_err = M.read_manifest(history_dir, root_trace_id)
  if not manifest then
    return nil, manifest_err or "trace manifest not found"
  end
  local events, events_err, parse_errors = M.read_events(history_dir, root_trace_id)
  if not events then
    return nil, events_err
  end
  local mode = opts.mode or "summary"
  local skip = math.max(0, math.floor(opts.skip or 0))
  local take = math.floor(opts.take or (mode == "full" and 200 or 50))
  if take < 1 then
    take = 1
  end
  local returned = {}
  for i = skip + 1, math.min(#events, skip + take) do
    table.insert(returned, summarize_event(events[i], mode))
  end
  local result = {
    source = "recorded",
    root_trace_id = root_trace_id,
    manifest = manifest,
    events = returned,
    total_events = #events,
    returned_events = #returned,
    skip = skip,
    take = take,
    mode = mode,
    parse_errors = parse_errors,
  }
  if opts.include_archives then
    local paths = M.paths(history_dir, root_trace_id)
    local archive_files = paths and vim.fn.glob(paths.archives_dir .. "/*.json", false, true) or {}
    result.archives = {}
    for _, file in ipairs(archive_files or {}) do
      local archive = read_json_optional(file)
      if archive then
        if mode == "summary" then
          table.insert(result.archives, {
            path = file,
            event_id = archive.event_id,
            source_save_id = archive.source_save_id,
            span_id = archive.span_id,
            range = archive.range,
            turn_count = #(archive.turns or {}),
          })
        else
          archive.path = file
          table.insert(result.archives, archive)
        end
      end
    end
  end
  return result, nil
end

--- 从 saved chat 消息合成事件（synth_* event ids；fragment 消息附 fragment.inserted）。
---@param save_id string @param chat_data table @param mode string
---@return table[] events
local function synthesize_messages(save_id, chat_data, mode)
  local membership = M.get_membership(chat_data)
    or M.create_root_membership(save_id, { span_id = "synth_" .. M.hash(save_id):sub(1, 12) })
  local events = {}
  for index, msg in ipairs(chat_data.messages or {}) do
    if is_visible_conversation_message(msg) then
      local event = M.message_to_turn_event(save_id, chat_data, membership, msg, index)
      if event then
        event.event_id = "synth_" .. M.hash(event.dedupe_key):sub(1, 16)
        event.created_at = chat_data.updated_at
        event.synthesized = true
        event.evidence = { save_id = save_id, message_index = index }
        table.insert(events, summarize_event(event, mode))
      end
    end
    if type(msg) == "table" and msg._meta and msg._meta.inserted_from_fragment then
      local fragment_event = {
        schema_version = M.SCHEMA_VERSION,
        event_id = "synth_fragment_" .. M.hash(save_id .. ":" .. tostring(index)):sub(1, 16),
        root_trace_id = save_id,
        kind = "fragment.inserted",
        created_at = chat_data.updated_at,
        span_id = membership.span_id,
        parent_span_id = membership.parent_span_id,
        session = session_info(chat_data, membership),
        fragment = vim.deepcopy(msg._meta.inserted_from_fragment),
        synthesized = true,
        evidence = { save_id = save_id, message_index = index },
      }
      table.insert(events, fragment_event)
    end
  end
  return events
end

--- 读取 saved chat 信封（chats/<save_id>.json）。
---@param history_dir string @param save_id string
---@return table|nil chat_data
---@return string|nil err
local function read_saved_chat(history_dir, save_id)
  if not is_plain_id(save_id) then
    return nil, "save_id must be a non-empty path-safe id"
  end
  local path = history_dir .. "/chats/" .. save_id .. ".json"
  return read_json_optional(path)
end

--- 合成 trace（无 recorded trace 时的回退）：从 saved chat 合成事件，
--- 返回带 gaps 标注的 manifest。不写盘。
---@param history_dir string
---@param save_id string
---@param opts? {mode?: "summary"|"full", skip?: integer, take?: integer}
---@return table|nil result {source="synthesized", root_trace_id, save_id, manifest, events,
---  total_events, returned_events, skip, take, mode, gaps}
---@return string|nil err
function M.synthesize_trace(history_dir, save_id, opts)
  opts = opts or {}
  local chat_data, err = read_saved_chat(history_dir, save_id)
  if not chat_data then
    return nil, err or "saved chat not found"
  end
  local mode = opts.mode or "summary"
  local all_events = synthesize_messages(save_id, chat_data, mode)
  local skip = math.max(0, math.floor(opts.skip or 0))
  local take = math.floor(opts.take or (mode == "full" and 200 or 50))
  if take < 1 then
    take = 1
  end
  local returned = {}
  for i = skip + 1, math.min(#all_events, skip + take) do
    table.insert(returned, all_events[i])
  end
  local gaps = {
    {
      kind = "unrecorded_runtime_lineage",
      detail = "Synthesis reads only saved chat messages; temporary child sessions, deleted scratch chats, and unarchived compressed raw ranges may be unrecoverable.",
    },
  }
  local meta = chat_data._meta
  local rs = chat_data.runtime_state
  if
    (type(meta) == "table" and (meta.compaction or meta.compact or meta.cc_history_compression))
    or (type(rs) == "table" and (rs.compaction or rs.compact or rs.compression))
  then
    table.insert(gaps, {
      kind = "compression_raw_range_may_be_missing",
      detail = "Saved chat contains compression metadata but no trace archive was recorded for missing raw prompt/reply pairs.",
    })
  end
  return {
    source = "synthesized",
    root_trace_id = save_id,
    save_id = save_id,
    manifest = {
      schema_version = M.SCHEMA_VERSION,
      root_trace_id = save_id,
      root_save_id = save_id,
      root_title = chat_data.title,
      status = "synthesized",
      created_at = chat_data.created_at,
      updated_at = chat_data.updated_at,
      source = "saved_chat_history",
    },
    events = returned,
    total_events = #all_events,
    returned_events = #returned,
    skip = skip,
    take = take,
    mode = mode,
    gaps = gaps,
  },
    nil
end

--- 三级查找 save_id -> root_trace_id：
--- direct（trace 目录 = save_id）/ chat_meta（saved chat 信封 trace.membership）/ index（扫描 index.save_ids）。
---@param history_dir string
---@param save_id string
---@return string|nil trace_id
---@return string|nil source "direct"|"chat_meta"|"index"
function M.find_trace_id_for_save_id(history_dir, save_id)
  if not is_plain_id(save_id) then
    return nil, "save_id must be a non-empty path-safe id"
  end
  if M.trace_exists(history_dir, save_id) then
    return save_id, "direct"
  end
  local chat_data = read_saved_chat(history_dir, save_id)
  if type(chat_data) == "table" then
    local membership = M.get_membership(chat_data)
    if membership and membership.root_trace_id then
      return membership.root_trace_id, "chat_meta"
    end
  end
  local traces_dir = M.traces_dir(history_dir)
  if vim.fn.isdirectory(traces_dir) == 0 then
    return nil, nil
  end
  local dirs = vim.fn.glob(traces_dir .. "/*", false, true)
  for _, dir in ipairs(dirs or {}) do
    local root_trace_id = vim.fn.fnamemodify(dir, ":t")
    local index = M.read_index(history_dir, root_trace_id)
    if type(index) == "table" and index.save_ids and index.save_ids[save_id] then
      return root_trace_id, "index"
    end
  end
  return nil, nil
end

--- 测试/诊断暴露的内部原语。
M._test = {
  is_plain_id = is_plain_id,
  normalize_content = normalize_content,
  truncate_content = truncate_content,
  is_visible_conversation_message = is_visible_conversation_message,
}

return M
