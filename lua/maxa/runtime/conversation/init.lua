-- filepath: lua/maxa/runtime/conversation/init.lua
--- maxa runtime normalized message model + message stack (phase-0 minimal scope).
---
--- Delivers the normalized-message construction/serialization helpers for phase 0
--- (§4.3 of .supermax/drafts/phase0-development-plan.md) and the identity contract
--- (§4.4): stable per-message `_meta.id`, monotonic `_meta.index`, and `_meta.cycle`
--- as the regeneration generation for the same index.
---
--- Upstream alignment (read-only, never copied): `codecompanion/types.lua`
--- `Message` type + `codecompanion/interactions/chat/init.lua::Chat:add_message`
--- (message normalization from `data = {role, content?, reasoning?, tool_calls?}`,
--- tools.calls mapping, `_meta = { id, cycle, index }`, index = #messages+1 at
--- insertion time).
---
--- Dependencies: only `lua/maxa/runtime/schema` (topology: schema -> conversation).
--- It never loads `codecompanion.*`/`mcphub.*`/`lua/util/hooks/*`. Later phase adds
--- content-parts/context/reasoning enrichment (message-context-target); those fields
--- stay optional placeholders here so the normalized shape remains forward-compatible.

local schema = require("maxa.runtime.schema")

local M = {}

M.name = "conversation"

--- FNV-1a 32-bit content hash. Deterministic across runs; used purely to seed a
--- message id (not cryptographic). Pure-Lua so it never depends on nvim internals.
---@param s string
---@return string
local function fnv1a(s)
  local h = 2166136261
  for i = 1, #s do
    h = bit.bxor(h, s:byte(i, i) or 0)
    h = (h * 16777619) % 4294967296
  end
  return tostring(h)
end

--- Deterministic content hash over a plain value (JSON-encoded when possible).
---@param val any
---@return string
local function content_hash(val)
  local ok, json = pcall(vim.json.encode, val)
  if not ok then
    json = tostring(val)
  end
  return fnv1a(json)
end

-- Deep-copy a plain value for stack-owned message copies so the caller and the
-- stack never share mutable identity fields. Uses the LazyVim/nvim built-in
-- `vim.deepcopy` (R07-era cleanup: the previous hand-written cycle-safe deepcopy was
-- redundant; normalized messages are JSON-safe plain values without cycles, so the
-- nvim primitive is a drop-in, and it is already used elsewhere in this runtime).
---@generic T
---@param v T
---@return T
local deepcopy = vim.deepcopy

----------------------------------------------------------------------------
-- Identity
----------------------------------------------------------------------------

--- Create a fresh identity allocator for one message stack.
---
--- The allocator owns the counters a stack needs:
---   * `index` : assigned to the next appended message (starts at 0, so the first
---               appended message gets index 1, aligned to upstream #messages + 1).
---   * `cycle` : current regeneration generation for an index; `bump_cycle()`
---               advances it when an existing index is regenerated.
---   * `seed`  : per-stack origin so derived message ids are unique across sessions
---               even for structurally identical messages.
---@param opts? table { seed?: string }
---@return table identity
function M.new_identity(opts)
  opts = opts or {}
  local seed = opts.seed
  if not seed or type(seed) ~= "string" then
    seed = tostring(os.time()) .. ":" .. tostring(math.random(1, 1e9))
  end
  local id = {
    seed = seed,
    index = 0,
    cycle = 0,
  }
  function id:next_index()
    self.index = self.index + 1
    return self.index
  end
  function id:bump_cycle()
    self.cycle = self.cycle + 1
    return self.cycle
  end
  return id
end

--- Generate a stable message id. A caller-supplied `stable_id` wins and is used
--- verbatim (identity is immutable once set). Otherwise the id is derived from the
--- identity seed + content hash: stable for equal content within one session, and
--- unique across sessions via the per-stack seed.
---@param idctx table identity allocator
---@param content any content exchanged into the id hash
---@param stable_id? string|nil caller-supplied stable id
---@return string
function M.make_id(idctx, content, stable_id)
  if stable_id ~= nil and type(stable_id) == "string" then
    return stable_id
  end
  local seed = (idctx and idctx.seed) or ""
  return "m:" .. seed .. ":" .. content_hash(content)
end

----------------------------------------------------------------------------
-- Message construction
----------------------------------------------------------------------------

--- Normalize caller-provided `tools` / `tool_calls` into the `{ calls = <list> }`
--- shape the schema requires. nil input yields nil (no `tools` key), matching
--- upstream `add_message` where tools appears only when tool data is supplied.
---@param tools any `{ calls = {...} }`, a bare list, or nil
---@return table? nil|{ calls = table }
local function normalize_tools(tools)
  if tools == nil then
    return nil
  end
  if type(tools) ~= "table" then
    error("conversation: message `tools` must be a table")
  end
  local calls = tools.calls
  if calls == nil then
    calls = tools -- bare list form
  end
  if type(calls) ~= "table" then
    error("conversation: message `tools.calls` must be a table")
  end
  return { calls = calls }
end

--- Deterministic seed content for id hashing (stable subset of the message).
---@param data table
---@return table
local function message_seed_content(data)
  return { role = data.role, content = data.content }
end

--- Build the identity block for a message.
---@param idctx table identity allocator
---@param content any id hash seed content
---@param explicit_meta table|nil caller-supplied _meta extra fields (e.g. tag)
---@param index integer assigned index
---@param cycle integer assigned cycle
---@return table _meta
local function build_meta(idctx, content, explicit_meta, index, cycle)
  local meta = {
    id = M.make_id(idctx, content, explicit_meta and explicit_meta.id),
    index = index,
    cycle = cycle,
  }
  if explicit_meta then
    for k, v in pairs(explicit_meta) do
      if k ~= "id" and k ~= "index" and k ~= "cycle" then
        meta[k] = v
      end
    end
  end
  return meta
end

--- Construct a single normalized message (§4.3), aligned to `Chat:add_message`.
---
---@param data table {
---   role:        "user"|"assistant"|"system"|"tool",
---   content?:    string|nil,
---   reasoning?:  table|nil,
---   tool_calls?: table[]|nil, -- mapped to tools.calls
---   tools?:      table|nil,   -- may be { calls = {...} } or a bare list
--- }
---@param opts? table {
---   idctx?:     table identity allocator (defaults to a fresh ephemeral allocator),
---   index?:     integer, indexed position (defaults to idctx:next_index())
---   cycle?:     integer, regeneration generation (defaults to idctx.cycle)
---   stable_id?: string,  caller-supplied immutable message id
---   context?:   table,   context placeholder stored on message.context
---   visible?:   boolean, forwarded into opts
---   _meta?:     table,   extra protocol/tag fields merged into _meta
--- }
---@return table normalized message
function M.new_message(data, opts)
  if type(data) ~= "table" or not data.role then
    error("conversation.new_message: data.role is required")
  end

  opts = opts or {}
  local idctx = opts.idctx or M.new_identity()

  local tool_bag = normalize_tools(data.tools or data.tool_calls)

  local o = {}
  if opts.visible ~= nil then
    o.visible = opts.visible
  end
  if type(data.opts) == "table" then
    for k, v in pairs(data.opts) do
      o[k] = v
    end
  end

  -- Build without tools default (upstream shape: tools present only when tool data
  -- is supplied); schema tolerates missing `tools` (it is optional).
  -- A caller-supplied `stable_id` must be forwarded into the identity block so it
  -- wins over the content-derived id (immutable identity contract §4.4).
  local meta_fields = opts._meta or {}
  if opts.stable_id ~= nil then
    meta_fields = vim.tbl_deep_extend("force", { id = opts.stable_id }, meta_fields)
  end
  local message = {
    role = data.role,
    content = data.content,
    reasoning = data.reasoning or opts.reasoning,
    _meta = build_meta(
      idctx,
      message_seed_content(data),
      meta_fields,
      opts.index or idctx:next_index(),
      opts.cycle or idctx.cycle
    ),
  }
  if tool_bag then
    message.tools = tool_bag
  end
  if not vim.tbl_isempty(o) then
    message.opts = o
  end
  if opts.context ~= nil then
    message.context = opts.context
  end

  local verr = schema.validate(schema.message, message, { skip_underscore = false })
  if verr then
    error("conversation.new_message: invalid message: " .. vim.inspect(verr))
  end

  return message
end

----------------------------------------------------------------------------
-- Message stack
----------------------------------------------------------------------------

--- Ordered message stack (the phase-0 `messages` sequence of a conversation).
--- Mirrors upstream `self.messages` with `add_message` semantics for appending,
--- plus mutation-free iteration and a serialization round-trip.
local Stack = {}
Stack.__index = Stack

--- Create a message stack, optionally seeding a fresh identity allocator.
---@param opts? table { idctx?: table }
---@return table stack
function M.new_stack(opts)
  local self = setmetatable({}, Stack)
  opts = opts or {}
  self.idctx = opts.idctx or M.new_identity()
  self.messages = {}
  return self
end
Stack.new = M.new_stack

--- Length (number of messages).
---@return integer
function Stack:len()
  return #self.messages
end

--- Append a normalized message, assigning its index = #stack+1 (aligned to upstream
--- `#self.messages + 1`). Deep-copies so caller and stack never share identity.
---@param data table message data (see M.new_message)
---@param opts? table message options (see M.new_message)
---@return self chaining (aligned to `Chat:add_message` returning self)
function Stack:add_message(data, opts)
  opts = opts or {}
  if opts.index == nil then
    opts.index = self:len() + 1
  end
  self.messages[#self.messages + 1] = M.new_message(data, opts)
  return self
end

--- Append a raw, already-normalized message (owned copy).
---@param msg table normalized message
---@return self
function Stack:push(msg)
  self.messages[#self.messages + 1] = deepcopy(msg)
  return self
end

--- Iterate messages in insertion order: `for msg in stack:iter() do ... end`.
---@return function iterator
function Stack:iter()
  local i = 0
  return function()
    i = i + 1
    return self.messages[i]
  end
end

--- Get a message by 1-based index.
---@param idx integer
---@return table? msg
function Stack:get(idx)
  return self.messages[idx]
end

--- Last message.
---@return table? msg
function Stack:last()
  return self.messages[#self.messages]
end

--- Replace the last assistant message (regeneration) keeping its index but bumping
--- the cycle generation for that index (identity contract §4.4). If the stack is
--- empty, defers to `add_message`.
---@param data table message data
---@param opts? table message options (stable_id honoured to keep identity stable)
---@return table? prev previous assistant message (nil when stack empty)
---@return table new_msg
function Stack:replace_last_assistant(data, opts)
  opts = opts or {}
  local idx = self:len()
  local prev = self.messages[idx]
  local index = (prev and prev._meta and prev._meta.index) or (idx + 1)
  local cycle = (prev and prev._meta and prev._meta.cycle or 0) + 1
  if not prev then
    -- empty stack: append as index 1, cycle starts at 1
    return nil, self:add_message(data, opts)
  end
  local msg = M.new_message(data, {
    index = index,
    cycle = cycle,
    stable_id = prev._meta and prev._meta.id,
    context = opts.context,
    visible = opts.visible,
    _meta = opts._meta,
  })
  self.messages[idx] = msg
  return prev, msg
end

----------------------------------------------------------------------------
-- Serialization
----------------------------------------------------------------------------

--- Serialize a single normalized message to a plain JSON-safe table (identity kept
--- verbatim).
---@param msg table normalized message
---@return table plain
function M.serialize_message(msg)
  return deepcopy(msg)
end

--- Validate a message against the phase-0 schema.
---@param msg table
---@return boolean ok
---@return string|nil err
function M.validate_message(msg)
  if type(msg) ~= "table" then
    return false, "message must be a table"
  end
  local verr = schema.validate(schema.message, msg, { skip_underscore = false })
  if verr then
    return false, vim.inspect(verr)
  end
  return true, nil
end

--- Deserialize a serialized message back into a normalized message (validating it).
---@param t table serialized message
---@return table message
function M.deserialize_message(t)
  if type(t) ~= "table" or not t.role then
    error("conversation.deserialize_message: missing role")
  end
  local ok, err = M.validate_message(t)
  if not ok then
    error("conversation.deserialize_message: invalid message: " .. err)
  end
  return t
end

--- Serialize the whole stack to a JSON-safe array of plain messages.
---@return table[]
function Stack:to_table()
  local out = {}
  for i, msg in ipairs(self.messages) do
    out[i] = M.serialize_message(msg)
  end
  return out
end

--- Rebuild a stack from a serialized array (validates each entry).
---@param list table[]
---@return table stack
function M.stack_from_table(list)
  if type(list) ~= "table" then
    error("conversation.stack_from_table: expected a list")
  end
  local st = M.new_stack()
  for _, t in ipairs(list) do
    st:push(M.deserialize_message(t))
  end
  return st
end

--- Serialize a stack to a JSON string.
---@param stack table stack
---@return string
function M.to_json(stack)
  return vim.json.encode(stack:to_table())
end

--- Parse a JSON string back into a message stack.
---@param json string
---@return table stack
function M.from_json(json)
  local ok, decoded = pcall(vim.json.decode, json)
  if not ok or type(decoded) ~= "table" then
    error("conversation.from_json: invalid JSON payload")
  end
  return M.stack_from_table(decoded)
end

--- Round-trip a message (serialize -> deserialize -> validate).
---@param msg table
---@return table round_tripped
function M.roundtrip(msg)
  return M.deserialize_message(M.serialize_message(msg))
end

M.Stack = Stack

return M
