-- filepath: lua/maxa/runtime/history/compact.lua
--- Phase-4 W4 compaction policy + summary prompt（纯策略模块）。
---
--- 行为基线（只读参考，非依赖）：
---   * `codecompanion/interactions/chat/slash_commands/builtin/compact.lua`
---     （上游 v18.7.0 /compact 摘要 prompt 结构：Primary Request and Intent /
---     Key Technical Concepts / Files and Code Sections / Problem Solving /
---     Pending Tasks / Current Work / Optional Next Step / Supporting Quotes；
---     本模块对齐结构，措辞为 maxa 自有，不逐字复制）；
---   * `util/mcphub/cc_history/history_session.lua` apply_compression_result
---     （mode auto -> 当前会话 new / 已保存会话 overwrite；overwrite 原地替换
---     消息保存；new 生成 `compact_` 前缀 save_id + compression provenance meta
---     {compressed_from, compressed_at, previous}）；
---   * `util/mcphub/cc_history/compaction_messages.lua`
---     （PROTECTED_PREFIX_FIELD = "compact_protected_prefix_count" 读写语义；
---     runtime_state 字段 + envelope.opts 镜像兼容）。
---
--- 本模块是纯策略/prompt 模块：不 require 存储、不 emit 事件、不依赖
--- orchestrator/session；编排在服务层（history/init.lua `Service:compact`）。
--- 可见性判定通过构造注入的 `trace`（M.is_visible_conversation_message），
--- 缺失时使用本模块保守内联判定（同一 IGNORED_TAGS 契约）。
--- 禁止加载 codecompanion.* / mcphub.* / lua/util/hooks/*（import-guard）。

local M = {}

M.PROTECTED_PREFIX_FIELD = "compact_protected_prefix_count"

M.COMPRESS_MODES = { AUTO = "auto", OVERWRITE = "overwrite", NEW = "new" }

--- 摘要消息标记 tag（trace IGNORED_NATURAL_TURN_TAGS 已含 compact_summary，
--- 因此摘要消息不构成 natural turn）。
M.SUMMARY_TAG = "compact_summary"

--- 构造默认配置。
M.DEFAULTS = { protected_prefix_default = 0 }

--- 与 trace 模块一致的忽略 tag 集合（可见性判定兜底）。
local IGNORED_TAGS = {
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

---@param value any
---@return integer
local function normalize_non_negative_integer(value)
  local n = tonumber(value)
  if not n then
    return 0
  end
  n = math.floor(n)
  if n < 0 then
    return 0
  end
  return n
end

--- 保守可见性判定（无注入 trace 时使用；与 trace.is_visible_conversation_message 同契约）。
---@param msg any
---@return boolean
local function default_visible_message(msg)
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
  if meta.tag and IGNORED_TAGS[meta.tag] then
    return false
  end
  if msg.role == "user" or msg.role == "llm" or msg.role == "assistant" then
    return not (msg.tools and (msg.tools.calls or msg.tools.call_id))
  end
  return false
end

--- 读取 protected prefix 计数（对齐 compaction_messages.get_protected_prefix_count）：
--- 优先 holder.runtime_state[FIELD]，其次 holder.opts[FIELD]（信封 legacy 镜像），
--- 最后 holder[FIELD]（直接传入 runtime_state 形状）。缺省 0。
---@param holder table|nil
---@return integer
function M.get_protected_prefix_count(holder)
  if type(holder) ~= "table" then
    return 0
  end
  if type(holder.runtime_state) == "table" and holder.runtime_state[M.PROTECTED_PREFIX_FIELD] ~= nil then
    return normalize_non_negative_integer(holder.runtime_state[M.PROTECTED_PREFIX_FIELD])
  end
  if type(holder.opts) == "table" and holder.opts[M.PROTECTED_PREFIX_FIELD] ~= nil then
    return normalize_non_negative_integer(holder.opts[M.PROTECTED_PREFIX_FIELD])
  end
  if holder[M.PROTECTED_PREFIX_FIELD] ~= nil then
    return normalize_non_negative_integer(holder[M.PROTECTED_PREFIX_FIELD])
  end
  return 0
end

--- 写入 protected prefix 计数：
--- envelope/snapshot 形状（有 runtime_state）同时写 runtime_state[FIELD] 与
--- envelope.opts[FIELD]（legacy 兼容镜像）；纯 runtime_state 形状直接写字段。
---@param holder table
---@param count number|nil
---@return integer count
function M.set_protected_prefix_count(holder, count)
  local n = normalize_non_negative_integer(count)
  if type(holder) ~= "table" then
    return n
  end
  if type(holder.runtime_state) == "table" then
    holder.runtime_state[M.PROTECTED_PREFIX_FIELD] = n
    holder.opts = holder.opts or {}
    holder.opts[M.PROTECTED_PREFIX_FIELD] = n
  else
    holder[M.PROTECTED_PREFIX_FIELD] = n
  end
  return n
end

--- 解析压缩模式（对齐 apply_compression_result 的 auto 语义）：
--- auto -> is_current 为真 new，否则 overwrite；overwrite/new 原样；非法返回 nil。
---@param mode string|nil
---@param opts? {is_current?: boolean}
---@return string|nil action "overwrite"|"new"
function M.apply_modes(mode, opts)
  opts = opts or {}
  mode = mode or M.COMPRESS_MODES.AUTO
  if mode == M.COMPRESS_MODES.AUTO then
    return opts.is_current and M.COMPRESS_MODES.NEW or M.COMPRESS_MODES.OVERWRITE
  end
  if mode == M.COMPRESS_MODES.OVERWRITE or mode == M.COMPRESS_MODES.NEW then
    return mode
  end
  return nil
end

--- 计算 protected 区域终点：前 N 个可见 user 消息（含该消息）为止的下标。
--- count<=0 -> 0；可见 user 少于 N -> 最后一个可见 user 消息下标。
---@param messages table[]
---@param count number|nil
---@param opts? {visible_fn?: fun(msg: table): boolean}
---@return integer protected_end
function M.compute_protected_boundary(messages, count, opts)
  opts = opts or {}
  local visible_fn = opts.visible_fn
  count = normalize_non_negative_integer(count)
  if count <= 0 or type(messages) ~= "table" then
    return 0
  end
  local seen = 0
  local last_visible_user = 0
  for i, msg in ipairs(messages) do
    if type(msg) == "table" and msg.role == "user" and (not visible_fn or visible_fn(msg)) then
      last_visible_user = i
      seen = seen + 1
      if seen >= count then
        return i
      end
    end
  end
  return last_visible_user
end

--- 提取消息可读文本（content 字符串 / content-parts text 拼接）。
---@param msg table
---@return string|nil
local function message_text(msg)
  if type(msg) ~= "table" then
    return nil
  end
  local content = msg.content
  if type(content) == "string" then
    return content
  end
  if type(content) == "table" then
    local out = {}
    for _, part in ipairs(content) do
      if type(part) == "table" and part.type == "text" then
        local t = part.text or part.content
        if type(t) == "string" then
          out[#out + 1] = t
        end
      end
    end
    if #out > 0 then
      return table.concat(out)
    end
  end
  return nil
end

--- 构建压缩摘要 prompt（结构对齐上游 /compact，措辞为 maxa 自有）。
--- 仅纳入可见 user/assistant 消息；opts.range 限定时只使用该闭区间。
---@param messages table[]
---@param opts? {visible_fn?: fun(msg: table): boolean, range?: {start_index: integer, end_index: integer}}
---@return string prompt
function M.build_summary_prompt(messages, opts)
  opts = opts or {}
  local visible_fn = opts.visible_fn
  local start_i = 1
  local end_i = #(messages or {})
  if type(opts.range) == "table" then
    start_i = math.max(1, math.floor(tonumber(opts.range.start_index) or 1))
    end_i = math.min(end_i, math.floor(tonumber(opts.range.end_index) or end_i))
  end
  local parts = {}
  for i = start_i, end_i do
    local msg = messages[i]
    if type(msg) == "table" then
      local role = msg.role == "llm" and "assistant" or msg.role
      if (role == "user" or role == "assistant") and (not visible_fn or visible_fn(msg)) then
        local text = message_text(msg)
        if text and vim.trim(text) ~= "" then
          parts[#parts + 1] = string.format('<message role="%s">%s</message>', role, vim.trim(text))
        end
      end
    end
  end
  local conversation = table.concat(parts, "\n")
  return table.concat({
    [[Your task is to produce a detailed summary of the conversation so far, capturing the user's explicit requests and the technical work that was performed. The summary must be precise enough that development can continue from the remaining messages without the original text.]],
    "",
    [[Analyze the conversation first, then output only a Markdown summary with the following sections, each introduced by a Markdown header:]],
    "",
    [[- "Primary Request and Intent": capture every explicit user request and goal in detail.]],
    [[- "Key Technical Concepts": list the technologies, frameworks and important concepts discussed.]],
    [[- "Files and Code Sections": enumerate the files examined, modified or created; give the most recent work priority, include full code snippets where important, and explain why each file matters.]],
    [[- "Problem Solving": document solved problems and any troubleshooting that is still in progress.]],
    [[- "Pending Tasks": list tasks the user explicitly asked for that are not finished yet.]],
    [[- "Current Work": describe precisely what was being worked on immediately before this summary, focusing on the most recent user and assistant messages; include file names and code where relevant.]],
    [[- "Optional Next Step": give the immediate next step that is directly in line with the user's explicit requests and the work that was just being done. Only list a step if it continues the current task; do not invent tangential work.]],
    [[- "Supporting Quotes": include verbatim quotes from the most recent conversation showing the exact task and where work stopped.]],
    "",
    [[Output only the Markdown summary itself, without commentary or extra formatting. If you reference code, wrap it in FOUR backticks followed by the appropriate language identifier.]],
    "",
    [[The conversation to summarize is:]],
    "",
    [[<conversation>]] .. conversation .. [[</conversation>]],
  }, "\n")
end

local Compact = {}
Compact.__index = Compact

--- 构造 Compact 策略实例。
---@param opts {config?: table, ids?: table, storage?: table, trace?: table,
---  provider_resolver?: fun(ctx: table): table|nil}
---@return table compact
function M.new(opts)
  opts = opts or {}
  local self = setmetatable({}, Compact)
  self.config = vim.tbl_deep_extend("force", vim.deepcopy(M.DEFAULTS), opts.config or {})
  self.ids = opts.ids
  self.storage = opts.storage
  self.trace = opts.trace
  self.provider_resolver = opts.provider_resolver
  return self
end

--- 实例可见性判定函数（注入 trace 优先）。
---@return fun(msg: table): boolean
function Compact:visible_fn()
  if self.trace and type(self.trace.is_visible_conversation_message) == "function" then
    return self.trace.is_visible_conversation_message
  end
  return default_visible_message
end

--- 实例 protected 计数：显式字段优先；未设置时使用配置默认。
---@param holder table|nil
---@return integer
function Compact:protected_prefix_count(holder)
  local v = M.get_protected_prefix_count(holder)
  if v == 0 and type(holder) == "table" then
    local rs = holder.runtime_state
    local explicit = (type(rs) == "table" and rs[M.PROTECTED_PREFIX_FIELD] ~= nil)
      or (type(holder.opts) == "table" and holder.opts[M.PROTECTED_PREFIX_FIELD] ~= nil)
      or (holder[M.PROTECTED_PREFIX_FIELD] ~= nil)
    if not explicit then
      return normalize_non_negative_integer(self.config.protected_prefix_default)
    end
  end
  return v
end

--- 实例 protected 边界。@param messages table[] @param count number|nil
---@return integer
function Compact:compute_protected_boundary(messages, count)
  return M.compute_protected_boundary(messages, count, { visible_fn = self:visible_fn() })
end

--- 实例摘要 prompt。@param messages table[] @param opts? table
---@return string
function Compact:build_summary_prompt(messages, opts)
  opts = opts or {}
  if opts.visible_fn == nil then
    opts = vim.deepcopy(opts)
    opts.visible_fn = self:visible_fn()
  end
  return M.build_summary_prompt(messages, opts)
end

M.Compact = Compact

return M
