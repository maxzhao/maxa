-- filepath: lua/maxa/runtime/skills/injector.lua
--- maxa runtime SkillHook injection + once-state (phase-3 W6).
---
--- Owns:
---   * pre-injection message construction: normalized conversation messages
---     with `_meta.provenance = { kind="skill_hook", skill_id, event_name,
---     inject_at, role, once?, once_key?, ephemeral? }`, persisted into the
---     session message stack (provenance survives serialization/restore);
---   * hook-role mapping (system/user/llm -> normalized roles; llm maps to
---     `assistant`);
---   * once/tombstone state: once hooks that injected carry `once=true` in
---     their provenance; `once` + `ephemeral` additionally write a hidden
---     tombstone message (`_meta.tag="skill_hook_tombstone"`) so once state is
---     durable even after the ephemeral payload is removed by the request
---     lifecycle (later wave);
---   * `restore_once_state(session_id, messages)`: rebuilds fired-once keys
---     from history (injected once markers + tombstones) so a restored session
---     never injects a second time (downstream injector.restore_once_state
---     semantics, rebuilt on the maxa message structure).
---
--- Dependencies: `maxa.runtime.conversation` (message model),
--- `maxa.runtime.events` (bus + constants). Never loads `codecompanion.*` /
--- `mcphub.*` / `lua/util/hooks/*`.

local conversation = require("maxa.runtime.conversation")
local events_mod = require("maxa.runtime.events")
local schema = require("maxa.runtime.schema")

local M = {}

M.name = "skills.injector"
M.VERSION = 1

--- Hook prompt roles -> normalized conversation roles.
M.ROLE_MAP = { system = "system", user = "user", llm = "assistant" }

M.INJECT_TAG = "skill_hook"
M.TOMBSTONE_TAG = "skill_hook_tombstone"
M.TOMBSTONE_CONTENT = "[skill_hook:state]"

--- Stable once key for a hook definition (session-independent, survives
--- restore through the provenance record).
---@param hook table parsed hook record
---@return string
function M.once_key(hook)
  return table.concat({ hook.skill_id, hook.event_name, hook.definition_hash }, "::")
end

--- Validate/normalize a Lua render() result into a prompt list. Returns
--- (nil, nil) when render returned nothing to inject (no-op, not an error).
---@param prompts any render result
---@param hook table parsed hook record
---@return table|nil normalized {role, content}[]
---@return table|nil err typed error
function M.normalize_prompts(prompts, hook)
  if prompts == nil then
    return nil, nil
  end
  if type(prompts) ~= "table" then
    return nil,
      schema.new_error(
        schema.ERROR.INVALID_ARGUMENT,
        ("skills.injector: lua hook %s render must return a prompt list or nil"):format(hook.path)
      )
  end
  local normalized = {}
  for i, prompt in ipairs(prompts) do
    if type(prompt) ~= "table" then
      return nil,
        schema.new_error(
          schema.ERROR.INVALID_ARGUMENT,
          ("skills.injector: lua hook %s prompt #%d must be a table"):format(hook.path, i)
        )
    end
    local role = prompt.role
    local content = prompt.content
    if type(role) ~= "string" or not M.ROLE_MAP[role] then
      return nil,
        schema.new_error(
          schema.ERROR.INVALID_ARGUMENT,
          ("skills.injector: lua hook %s prompt #%d has invalid role %q (expected system, user, or llm)"):format(
            hook.path,
            i,
            tostring(role)
          )
        )
    end
    if type(content) ~= "string" or vim.trim(content) == "" then
      return nil,
        schema.new_error(
          schema.ERROR.INVALID_ARGUMENT,
          ("skills.injector: lua hook %s prompt #%d content must be a non-empty string"):format(hook.path, i)
        )
    end
    local normalized_prompt = { role = role, content = content }
    if type(prompt._meta) == "table" then
      normalized_prompt._meta = vim.deepcopy(prompt._meta)
    end
    normalized[#normalized + 1] = normalized_prompt
  end
  if #normalized == 0 then
    return nil, nil
  end
  return normalized, nil
end

--- Create an injector instance (per-registry once state).
---@param opts? table { bus?: table|nil events bus for lifecycle projections }
---@return table inj
function M.new(opts)
  opts = opts or {}
  local bus = opts.bus or events_mod
  local inj = {
    bus = bus,
    fired = {}, -- session_id -> { [once_key]=true }
  }
  -- Instance passthrough for the module-level pure helpers.
  inj.once_key = M.once_key
  inj.normalize_prompts = M.normalize_prompts
  local self = setmetatable({}, { __index = inj })

  ---@param session_id string
  ---@param once_key string
  ---@return boolean
  function self.fired_once(session_id, once_key)
    local s = inj.fired[session_id]
    return s ~= nil and s[once_key] == true
  end

  ---@param session_id string
  ---@param once_key string
  function self.mark_fired(session_id, once_key)
    inj.fired[session_id] = inj.fired[session_id] or {}
    inj.fired[session_id][once_key] = true
  end

  ---@param session_id string
  function self.clear_session_state(session_id)
    inj.fired[session_id] = nil
  end

  --- Inject one prompt as a normalized message into a conversation stack.
  ---@param stack table conversation Stack (or add_message-compatible object)
  ---@param prompt table { role, content, _meta? }
  ---@param provenance table provenance record
  ---@param visible boolean
  ---@return table msg normalized message
  function self.inject_prompt(stack, prompt, provenance, visible)
    stack:add_message({ role = M.ROLE_MAP[prompt.role], content = { conversation.text_part(prompt.content) } }, {
      _meta = vim.tbl_deep_extend(
        "force",
        { provenance = vim.deepcopy(provenance), tag = M.INJECT_TAG },
        type(prompt._meta) == "table" and prompt._meta or {}
      ),
      visible = visible,
    })
    return stack:last()
  end

  --- Inject a hook's prompts into the session message stack with provenance.
  ---@param stack table conversation Stack
  ---@param hook table parsed hook record
  ---@param prompts table[] {role, content}[]
  ---@param opts? table {
  ---   visible?: boolean (default false = hidden),
  ---   once?: boolean, once_key?: string,
  ---   ephemeral?: boolean
  --- }
  ---@return table result { injected=integer, messages=table[] }
  function self.inject(stack, hook, prompts, opts)
    opts = opts or {}
    local result = { injected = 0, messages = {} }
    local provenance = {
      kind = M.INJECT_TAG,
      skill_id = hook.skill_id,
      event_name = hook.event_name,
      inject_at = hook.inject_at,
      once = opts.once == true and true or nil,
      once_key = opts.once == true and (opts.once_key or M.once_key(hook)) or nil,
      ephemeral = opts.ephemeral == true and true or nil,
    }
    for _, prompt in ipairs(prompts) do
      local prov = vim.deepcopy(provenance)
      prov.role = prompt.role
      local msg = self.inject_prompt(stack, prompt, prov, opts.visible == true)
      result.injected = result.injected + 1
      result.messages[#result.messages + 1] = msg
    end
    return result
  end

  --- Write a hidden tombstone message preserving a once hook's fired state
  --- (used for once + ephemeral: the payload message is removed by the request
  --- lifecycle later, the tombstone keeps the durable once marker).
  ---@param stack table conversation Stack
  ---@param hook table parsed hook record
  ---@param opts? table { once_key?: string }
  ---@return table msg tombstone message
  function self.write_tombstone(stack, hook, opts)
    opts = opts or {}
    stack:add_message({ role = "system", content = { conversation.text_part(M.TOMBSTONE_CONTENT) } }, {
      _meta = {
        tag = M.TOMBSTONE_TAG,
        provenance = {
          kind = M.TOMBSTONE_TAG,
          skill_id = hook.skill_id,
          event_name = hook.event_name,
          inject_at = hook.inject_at,
          once_key = opts.once_key or M.once_key(hook),
        },
      },
      visible = false,
    })
    return stack:last()
  end

  --- Rebuild fired-once keys from history (injected once markers + tombstones).
  --- No second injection after restore.
  ---@param session_id string
  ---@param messages table[] serialized/normalized messages
  ---@return integer restored count
  function self.restore_once_state(session_id, messages)
    if type(messages) ~= "table" then
      return 0
    end
    local restored = 0
    local function mark(once_key)
      if type(once_key) == "string" and once_key ~= "" and not self.fired_once(session_id, once_key) then
        self.mark_fired(session_id, once_key)
        restored = restored + 1
      end
    end
    for _, msg in ipairs(messages) do
      local prov = msg and msg._meta and msg._meta.provenance
      if type(prov) == "table" then
        if prov.kind == M.TOMBSTONE_TAG and prov.once_key then
          mark(prov.once_key)
        elseif prov.kind == M.INJECT_TAG and prov.once == true and prov.once_key then
          mark(prov.once_key)
        end
      end
    end
    if restored > 0 then
      bus.emit(events_mod.events.skill_hook_restored, {
        session_id = session_id,
        phase = "restore",
        ok = true,
        restored = restored,
        error = nil,
      })
    end
    return restored
  end

  return self
end

return M
