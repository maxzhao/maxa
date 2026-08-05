-- filepath: lua/maxa/runtime/conversation/init.lua
--- maxa runtime normalized message model + message stack (phase-1 W2).
---
--- Delivers the message-context-target normalized records (§Normalized records):
--- messages carry a `content` list of content parts (text/reasoning/image/
--- tool_call/tool_result/context_ref) with NO string-content compatibility layer;
--- identity is the stable top-level `id` + provider-neutral `turn_id`; the stack
--- keeps the phase-0 identity allocator (index/cycle) for regeneration semantics.
---
--- Upstream alignment (read-only, never copied): `codecompanion/types.lua`
--- `Message` type + `codecompanion/interactions/chat/init.lua::Chat:add_message`
--- (message normalization from `data = {role, content?, reasoning?, tool_calls?}`,
--- index = #messages+1 at insertion time).
---
--- Dependencies: only `lua/maxa/runtime/schema` (topology: schema -> conversation).
--- It never loads `codecompanion.*`/`mcphub.*`/`lua/util/hooks/*`.

local schema = require("maxa.runtime.schema")

local M = {}

M.name = "conversation"

--- Deterministic minimal user instruction for context-only submissions
--- (message-context-target §Submission validation: generated and marked synthetic).
M.SYNTHETIC_INSTRUCTION = "Answer based on the selected context."

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
-- `vim.deepcopy` (normalized messages are JSON-safe plain values without cycles).
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
-- Content-part construction (message-context-target §Normalized records)
----------------------------------------------------------------------------

--- Build a `text` content part (UTF-8 + optional language/media metadata).
---@param text string UTF-8 text
---@param opts? table { language?: string, media?: table }
---@return table part
function M.text_part(text, opts)
  opts = opts or {}
  local part = { type = "text", text = tostring(text or "") }
  if opts.language ~= nil then
    part.language = opts.language
  end
  if opts.media ~= nil then
    part.media = opts.media
  end
  return part
end

--- Build a `reasoning` content part: content + provider round-trip metadata,
--- kept separate from visible assistant text; retention follows provider/model
--- policy (opts.retained).
---@param content string reasoning text
---@param opts? table { signature?: string, provider?: string, retained?: boolean }
---@return table part
function M.reasoning_part(content, opts)
  opts = opts or {}
  local part = { type = "reasoning", content = tostring(content or "") }
  if opts.signature ~= nil then
    part.signature = opts.signature
  end
  if opts.provider ~= nil then
    part.provider = opts.provider
  end
  if opts.retained ~= nil then
    part.retained = opts.retained
  end
  return part
end

--- Build an `image` content part: MIME + runtime-owned blob reference.
--- The part stores the reference, not the payload; temporary payload expiry
--- must not invalidate a message already committed for a request.
---@param mime string MIME type
---@param blob_ref string runtime-owned payload/blob reference
---@param opts? table { source?: table }
---@return table part
function M.image_part(mime, blob_ref, opts)
  opts = opts or {}
  local part = { type = "image", mime = mime, blob_ref = blob_ref }
  if opts.source ~= nil then
    part.source = opts.source
  end
  return part
end

--- Build a `tool_call` content part: runtime call id + optional provider
--- id/provenance + tool name + encoded arguments (JSON text).
---@param call_id string runtime call id
---@param name string tool name
---@param arguments string encoded arguments (JSON text)
---@param opts? table { provider_id?: string }
---@return table part
function M.tool_call_part(call_id, name, arguments, opts)
  opts = opts or {}
  local part = { type = "tool_call", call_id = call_id, name = name, arguments = arguments or "" }
  if opts.provider_id ~= nil then
    part.provider_id = opts.provider_id
  end
  return part
end

--- Build a `tool_result` content part: paired call id + status + provider-facing
--- content. User display is a separate projection (renderer concern).
---@param call_id string paired tool_call call id
---@param status string "success"|"error"
---@param content string provider-facing result content
---@param opts? table { is_error?: boolean, provenance?: string }
---   provenance (W5, additive): synthetic-result marker (e.g. "restore_repair");
---   stored as an extra part field (schema content parts allow extra fields).
---@return table part
function M.tool_result_part(call_id, status, content, opts)
  opts = opts or {}
  local part = { type = "tool_result", call_id = call_id, status = status, content = tostring(content or "") }
  if opts.is_error ~= nil then
    part.is_error = opts.is_error
  end
  if opts.provenance ~= nil then
    part.provenance = opts.provenance
  end
  return part
end

--- Build a `context_ref` content part: stable context item id + snapshot/hash
--- (never an implicit live buffer pointer).
---@param item_id string stable context item id
---@param opts? table { snapshot?: string, hash?: string, kind?: string }
---@return table part
function M.context_ref_part(item_id, opts)
  opts = opts or {}
  local part = { type = "context_ref", item_id = item_id }
  if opts.snapshot ~= nil then
    part.snapshot = opts.snapshot
  end
  if opts.hash ~= nil then
    part.hash = opts.hash
  end
  if opts.kind ~= nil then
    part.kind = opts.kind
  end
  return part
end

--- Validate a content-part list (schema.validate_content wrapper).
---@param content any
---@return boolean ok
---@return string|nil err exact diagnostic
function M.validate_content(content)
  return schema.validate_content(content)
end

----------------------------------------------------------------------------
-- Message construction
----------------------------------------------------------------------------

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

--- Construct a single normalized message (§Normalized records).
--- `content` MUST be a list of content parts; there is no string-content
--- compatibility layer. `id`/`turn_id` live at the top level; `_meta`
--- (optional) mirrors the phase-0 identity block (index/cycle/tag).
---@param data table {
---   role:    "system"|"project"|"user"|"assistant"|"tool",
---   content?: table[]|nil, -- content parts (nil => empty list)
--- }
---@param opts? table {
---   idctx?:     table identity allocator (defaults to a fresh ephemeral allocator),
---   index?:     integer, indexed position (defaults to idctx:next_index())
---   cycle?:     integer, regeneration generation (defaults to idctx.cycle)
---   stable_id?: string,  caller-supplied immutable message id
---   turn_id?:   string,  provider-neutral turn id (defaults to the message id)
---   visible?:   boolean, forwarded into visibility ("visible"|"hidden")
---   provenance?: table,  provenance record (defaults to {})
---   created_at?: integer, wall-clock ms (defaults to now)
---   _meta?:     table,   extra identity fields merged into _meta
--- }
---@return table normalized message
function M.new_message(data, opts)
  if type(data) ~= "table" or not data.role then
    error("conversation.new_message: data.role is required")
  end

  opts = opts or {}
  local idctx = opts.idctx or M.new_identity()

  -- Full parts switch: content must be a list of valid content parts.
  local content = data.content
  if content == nil then
    content = {}
  end
  if type(content) ~= "table" or not schema.islist(content) then
    error("conversation.new_message: data.content must be a list of content parts")
  end
  local ok, cerr = schema.validate_content(content)
  if not ok then
    error("conversation.new_message: invalid content: " .. cerr)
  end

  -- Caller-supplied stable_id must win over the content-derived id.
  local meta_fields = opts._meta or {}
  if opts.stable_id ~= nil then
    meta_fields = vim.tbl_deep_extend("force", { id = opts.stable_id }, meta_fields)
  end
  local meta = build_meta(
    idctx,
    message_seed_content(data),
    meta_fields,
    opts.index or idctx:next_index(),
    opts.cycle or idctx.cycle
  )

  local message = {
    id = meta.id,
    turn_id = opts.turn_id or meta.id,
    role = data.role,
    content = deepcopy(content),
    visibility = opts.visible == false and "hidden" or (opts.visible == true and "visible" or "visible"),
    provenance = deepcopy(opts.provenance or {}),
    created_at = opts.created_at or schema.now_ms(),
    _meta = meta,
  }

  local verr = schema.validate(schema.message, message, { skip_underscore = false })
  if verr then
    error("conversation.new_message: invalid message: " .. vim.inspect(verr))
  end

  return message
end

----------------------------------------------------------------------------
-- Submission validation (message-context-target §Submission validation)
----------------------------------------------------------------------------

--- Validate a submission before a request is composed.
---
--- Semantics:
---   - whitespace-only text with no context items and no continuation record is
---     `empty-submit`: rejected, creates no request;
---   - context-only submission is valid when at least one selected item
---     contributes provider-visible content; a deterministic minimal user
---     instruction is generated and marked `synthetic`;
---   - an automatic continuation may submit an empty visible user string only
---     when complete paired tool results (or a protocol-required continuation
---     record) exist;
---   - missing/expired image payload, unresolved context source, or a
---     cross-project context item blocks composition with an exact
---     item/field diagnostic.
---
---@param input table {
---   text?: string,                 visible user text (may be empty)
---   context?: table[],             selected context items (see spec §Context items)
---   continuation?: table {         automatic-continuation record
---     tool_results?: table[],      complete paired tool results
---     protocol_required?: boolean  protocol requires a continuation turn
---   }
--- }
---@param opts? table { project_id?: string } session project id for cross-project checks
---@return table result {
---   ok=boolean,
---   kind="text"|"context_only"|"continuation",
---   instruction=string,   -- provider-visible instruction text
---   synthetic=boolean,    -- true when the instruction was auto-generated
--- } | { ok=false, error=table (typed), diagnostic=string }
function M.validate_submission(input, opts)
  input = input or {}
  opts = opts or {}
  local text = type(input.text) == "string" and input.text or ""
  local context = type(input.context) == "table" and input.context or {}
  local continuation = type(input.continuation) == "table" and input.continuation or {}

  -- Context item structure diagnostics first (exact item/field).
  local visible_items = 0
  for i, item in ipairs(context) do
    if type(item) ~= "table" then
      return {
        ok = false,
        error = schema.new_error(schema.ERROR.INVALID_ARGUMENT, "context item is not a table", nil, false),
        diagnostic = ("context[%d]: item must be a mapping"):format(i),
      }
    end
    if item.id == nil or item.id == "" then
      return {
        ok = false,
        error = schema.new_error(schema.ERROR.INVALID_ARGUMENT, "context item missing id", nil, false),
        diagnostic = ("context[%d].id: missing stable context item id"):format(i),
      }
    end
    -- Unresolved context source: a live item must declare kind + source + content
    -- (or a blob reference); generated summaries may carry only a snapshot.
    if item.kind == nil or item.kind == "" then
      return {
        ok = false,
        error = schema.new_error(schema.ERROR.INVALID_ARGUMENT, "context item missing kind", nil, false),
        diagnostic = ("context[%s].kind: unresolved context source (kind required)"):format(tostring(item.id)),
      }
    end
    if item.source == nil or item.source == "" then
      return {
        ok = false,
        error = schema.new_error(schema.ERROR.INVALID_ARGUMENT, "context item missing source", nil, false),
        diagnostic = ("context[%s].source: unresolved context source (source required)"):format(tostring(item.id)),
      }
    end
    -- Cross-project items are rejected unless explicitly rebound (transfer op is
    -- a later phase; here any mismatched project_id blocks composition).
    if opts.project_id ~= nil and item.project_id ~= nil and item.project_id ~= opts.project_id then
      return {
        ok = false,
        error = schema.new_error(schema.ERROR.INVALID_ARGUMENT, "cross-project context item", nil, false),
        diagnostic = ("context[%s].project_id: %s does not match session project %s"):format(
          tostring(item.id),
          tostring(item.project_id),
          tostring(opts.project_id)
        ),
      }
    end
    -- Missing/expired image payload: image items must reference a live blob.
    if item.kind == "image" then
      if item.blob_ref == nil or item.blob_ref == "" then
        return {
          ok = false,
          error = schema.new_error(schema.ERROR.INVALID_ARGUMENT, "image context item missing payload", nil, false),
          diagnostic = ("context[%s].blob_ref: missing image payload reference"):format(tostring(item.id)),
        }
      end
      if item.expired == true or item.payload_status == "expired" then
        return {
          ok = false,
          error = schema.new_error(schema.ERROR.INVALID_ARGUMENT, "image context item payload expired", nil, false),
          diagnostic = ("context[%s].blob_ref: image payload expired"):format(tostring(item.id)),
        }
      end
    end
    -- An item contributes provider-visible content when it carries content text
    -- or a blob reference (images) or a snapshot (generated summary).
    if item.content ~= nil or item.blob_ref ~= nil or item.snapshot ~= nil then
      visible_items = visible_items + 1
    end
  end

  local has_text = text:gsub("%s", "") ~= ""
  if has_text then
    return { ok = true, kind = "text", instruction = text, synthetic = false }
  end

  -- No visible text: continuation vs context-only vs empty-submit.
  local tool_results = type(continuation.tool_results) == "table" and continuation.tool_results or {}
  local paired = 0
  for _, tr in ipairs(tool_results) do
    if type(tr) == "table" and tr.call_id ~= nil then
      paired = paired + 1
    end
  end
  local can_continue = paired > 0 or continuation.protocol_required == true
  if can_continue then
    return { ok = true, kind = "continuation", instruction = "", synthetic = false }
  end

  if visible_items > 0 then
    return {
      ok = true,
      kind = "context_only",
      instruction = M.SYNTHETIC_INSTRUCTION,
      synthetic = true,
    }
  end

  return {
    ok = false,
    error = schema.new_error(
      schema.ERROR.INVALID_ARGUMENT,
      "empty submission: no visible text, context, or continuation record",
      nil,
      false
    ),
    diagnostic = "empty-submit: whitespace-only input with no new context",
  }
end

----------------------------------------------------------------------------
-- Message stack
----------------------------------------------------------------------------

--- Ordered message stack (the `messages` sequence of a conversation).
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
--- Insert a normalized message at a 1-based position (W5 restore-agent-loop
--- repair: synthetic tool results are injected immediately after the owning
--- assistant message, mirroring the downstream orphan-pairing behaviour). The
--- inserted message gets `_meta.index = idx`; existing messages keep their
--- identity (their `_meta.index` is NOT renumbered — identity contract).
---@param idx integer 1-based insert position (1..len+1)
---@param data table message data (see M.new_message)
---@param opts? table message options (see M.new_message)
---@return table msg the inserted normalized message
function Stack:insert_message(idx, data, opts)
  opts = opts or {}
  if opts.index == nil then
    opts.index = idx
  end
  local msg = M.new_message(data, opts)
  table.insert(self.messages, idx, msg)
  return msg
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
    turn_id = opts.turn_id,
    visible = opts.visible,
    provenance = opts.provenance,
    created_at = opts.created_at,
    _meta = opts._meta,
  })
  self.messages[idx] = msg
  return prev, msg
end

--- Remove every message after the last user message and return them in original
--- order (regeneration boundary, phase-2 W3: the last user turn is preserved
--- and becomes the new request context; the prior assistant attempt including
--- its tool calls and subsequent tool results is archived by the caller).
--- Returns nil when the stack has no user message (no mutation).
---@return table[]|nil removed prior assistant attempt messages
function Stack:truncate_after_last_user()
  local cut = 0
  for i = #self.messages, 1, -1 do
    if self.messages[i].role == "user" then
      cut = i
      break
    end
  end
  if cut == 0 then
    return nil
  end
  local removed = {}
  for i = cut + 1, #self.messages do
    removed[#removed + 1] = self.messages[i]
  end
  for i = #self.messages, cut + 1, -1 do
    self.messages[i] = nil
  end
  return removed
end

----------------------------------------------------------------------------
-- Serialization
----------------------------------------------------------------------------

--- Serialize a single normalized message to a plain JSON-safe table (identity kept
--- verbatim; content parts are JSON-safe by construction).
---@param msg table normalized message
---@return table plain
function M.serialize_message(msg)
  return deepcopy(msg)
end

--- Validate a message against the normalized schema (content-parts enforced).
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
  local ok, cerr = schema.validate_content(msg.content)
  if not ok then
    return false, cerr
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
