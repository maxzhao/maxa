-- filepath: lua/maxa/runtime/prompts/init.lua
--- maxa runtime system-prompt composer (phase-5 W5, C-001..C-004 core).
---
--- Pure composition pipeline (spec: supermax-configuration §Prompt composition /
--- §Target prompt template contract):
---
---   1. Resolve the project root once; all project paths use that snapshot.
---   2. Read the bundled runtime prompt (`<repo>/lua/maxa/prompts/system.md`)
---      and the optional project wrapper (`<root>/.maxa/system.md`).
---   3. Missing wrapper -> fallback to the bundled prompt (C-001). Present
---      wrapper MUST contain exactly one `<system_prompt>` placeholder
---      (C-002); it is expanded with the bundled full text first.
---   4. Expand Skill SYSTEM fragments per declared slot with deterministic
---      ordering; named-slot and duplicate-slot validation blocks composition.
---   5. Expand scalar placeholders (`<date>` `<vim_ver>` `<machine>`
---      `<root_dir>` `<skills_table>`) from one immutable composition snapshot.
---   6. Normalize line endings to LF.
---
--- The development mother repository's `.supermax/` is NEVER consulted.
--- `dump()` shares the exact compose pipeline; it only adds a redacted source
--- manifest (`redacted=true`), never changes the composed output.
---
--- Pure by contract: no file writes, no nvim state mutation (vim is used
--- read-only: fnamemodify/os_uname/version only).

local M = {}

M.name = "prompts"
M.VERSION = 1

-- Typed error kinds (spec-named; `code` stays schema-compatible "configuration").
M.ERROR_KINDS = {
  MISSING_SYSTEM_PROMPT_PLACEHOLDER = "missing-system-prompt-placeholder",
  DUPLICATE_SYSTEM_PROMPT_PLACEHOLDER = "duplicate-system-prompt-placeholder",
  DUPLICATE_SKILL_SLOT_PLACEHOLDER = "duplicate-skill-slot-placeholder",
  UNBOUND_SKILL_SYSTEM_SLOT = "unbound-skill-system-slot",
  MALFORMED_SKILL_SLOT_PLACEHOLDER = "malformed-skill-slot-placeholder",
  PROMPT_READ_ERROR = "prompt-read-error",
  INVALID_INPUT = "invalid-input",
}

M.BUNDLED_REL = "lua/maxa/prompts/system.md"
M.OVERRIDE_REL = ".maxa/system.md"
M.SLOT_DEFAULT = "default"
M.DEFAULT_PRIORITY = 100
M.SLOT_PATTERN = "^[A-Za-z0-9_-]+$"

-- Root of the development mother repository, derived from this module's source
-- path (same pattern as `lua/maxa/init.lua` M_ROOT): `@<repo>/lua/maxa/runtime/
-- prompts/init.lua`. Fallback to cwd keeps headless/standalone loads working.
local src = debug.getinfo(1, "S") and debug.getinfo(1, "S").source or ""
local M_ROOT = src:match("^@(.+)/lua/maxa/runtime/prompts/init%.lua$") or vim.fn.getcwd()

---@param kind string one of M.ERROR_KINDS
---@param message string
---@return table typed error { code="configuration", kind=..., message=..., terminal=true }
local function new_error(kind, message)
  return { code = "configuration", kind = kind, message = message, terminal = true }
end

---@param path string
---@return string|nil content
---@return string|nil err
local function read_text(path)
  local fh = io.open(path, "rb")
  if not fh then
    return nil, ("cannot open %s"):format(path)
  end
  local content = fh:read("*a")
  fh:close()
  return content, nil
end

--- Normalize line endings to LF (spec rule 10).
---@param s string
---@return string
local function to_lf(s)
  return (s:gsub("\r\n", "\n"):gsub("\r", "\n"))
end

--- Trim leading/trailing whitespace (including newlines). Interior content is
--- never trimmed (spec rule 10).
---@param s string
---@return string
local function trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

--- Deterministic FNV-1a 32-bit content hash (hex). `vim.hash_string` is not
--- available on the target Neovim build (LuaJIT 5.1 has no `~` operator), so
--- the pure-Lua bit library is used; this is a stable hash for the prompt
--- composition trace (spec: fragment content hash recorded in manifest).
---@param s string
---@return string 8-char lowercase hex
local bxor = bit and bit.bxor
  or function(a, b)
    local r, c = 0, 1
    while a > 0 or b > 0 do
      local aa, bb = a % 2, b % 2
      if aa ~= bb then
        r = r + c
      end
      a, b, c = math.floor(a / 2), math.floor(b / 2), c * 2
    end
    return r
  end

---@param s string
---@return string 8-char lowercase hex
local function fnv1a_hex(s)
  local h = 2166136261
  for i = 1, #s do
    h = bxor(h, s:byte(i))
    h = (h * 16777619) % 4294967296
  end
  return ("%08x"):format(h)
end

--- Host class normalization (`Linux`/`Windows`/`Mac`/raw fallback).
---@return string
local function detect_machine()
  local uname = (vim.uv and vim.uv.os_uname) and vim.uv.os_uname()
    or (vim.loop and vim.loop.os_uname and vim.loop.os_uname())
  local sys = uname and uname.sysname or ""
  if sys:match("^Linux$") or sys:match("Linux") then
    return "Linux"
  end
  if sys:match("Windows") or sys:match("MINGW") or sys:match("MSYS") or sys:match("CYGWIN") then
    return "Windows"
  end
  if sys:match("Darwin") then
    return "Mac"
  end
  return sys ~= "" and sys or "unknown"
end

--- Normalized Neovim semantic version.
---@return string
local function detect_vim_ver()
  local v = vim.version()
  if not v then
    return "unknown"
  end
  return ("%d.%d.%d"):format(v.major or 0, v.minor or 0, v.patch or 0)
end

--- Immutable composition snapshot: validates input and fixes scalar values once.
---@param opts table { root, now?, machine?, vim_ver? }
---@return table|nil ctx { root, date, machine, vim_ver }
---@return table|nil err typed error
local function snapshot(opts)
  local root = opts.root
  if type(root) ~= "string" or root == "" then
    return nil, new_error(M.ERROR_KINDS.INVALID_INPUT, "compose: opts.root must be a non-empty string")
  end
  local abs = vim.fn.fnamemodify(root, ":p")
  if abs:sub(-1) == "/" and #abs > 1 then
    abs = abs:sub(1, -2)
  end
  local date = opts.now
  if type(date) ~= "string" then
    date = os.date("%Y-%m-%d", type(date) == "number" and date or os.time())
  end
  local machine = opts.machine
  if type(machine) ~= "string" or machine == "" then
    machine = detect_machine()
  end
  local vim_ver = opts.vim_ver
  if type(vim_ver) ~= "string" or vim_ver == "" then
    vim_ver = detect_vim_ver()
  end
  return { root = abs, date = date, machine = machine, vim_ver = vim_ver }, nil
end

--- Normalize skills_state into an id -> record mapping (discovery shadowing is
--- the caller's responsibility; a record carries root_kind + metadata.system).
---@param skills_state? table
---@return table id -> record
local function normalize_records(skills_state)
  local out = {}
  if type(skills_state) ~= "table" then
    return out
  end
  local src = skills_state.records
  if type(src) ~= "table" then
    return out
  end
  for k, v in pairs(src) do
    if type(v) == "table" and type(v.id) == "string" then
      out[v.id] = v
    elseif type(k) == "string" and type(v) == "table" then
      out[k] = v
    end
  end
  return out
end

--- Global = config/bundled root kind; project is non-global. Falls back to the
--- metadata `visibility` field when root_kind is absent (synthetic tests).
---@param rec table
---@return boolean
local function record_is_global(rec)
  local kind = rec.root_kind
  if kind == "project" then
    return false
  end
  if kind == "config" or kind == "bundled" then
    return true
  end
  local vis = rec.metadata and rec.metadata.visibility
  return vis == "global"
end

--- Extract one eligible SYSTEM fragment from a discovery record, or nil.
---
--- Fragment declaration schema (`SKILL.md` frontmatter `system:` mapping):
---   slot               string|nil   empty/nil -> "default"; must match
---                                  [A-Za-z0-9_-]+ (invalid chars fail the
---                                  fragment, mirroring malformed-frontmatter
---                                  fail-closed behavior; it never elevates)
---   priority           number|nil   missing/non-number -> 100
---   allow_non_global   boolean|nil  default false
---   content            string       fragment markdown text (required)
--- Non-mapping `system` values are W6-validated, never interpreted here.
---@param rec table
---@return table|nil fragment { id, path, slot, priority, content }
local function extract_fragment(rec)
  if rec.valid == false then
    return nil
  end
  local md = rec.metadata
  if type(md) ~= "table" or md.system == nil or type(md.system) ~= "table" then
    return nil
  end
  local sys = md.system
  if type(sys.content) ~= "string" then
    return nil
  end
  local slot = sys.slot
  if slot == nil or slot == "" then
    slot = M.SLOT_DEFAULT
  end
  if type(slot) ~= "string" or not slot:match(M.SLOT_PATTERN) then
    return nil -- invalid slot characters: fragment fails validation
  end
  if not record_is_global(rec) and sys.allow_non_global ~= true then
    return nil -- non-global fragment requires explicit allow_non_global
  end
  local priority = type(sys.priority) == "number" and sys.priority or M.DEFAULT_PRIORITY
  return {
    id = rec.id,
    path = rec.file or rec.dir or rec.root or "<unknown>",
    slot = slot,
    priority = priority,
    content = to_lf(sys.content),
  }
end

--- Collect eligible fragments and group by slot; deterministic ordering is
--- applied at render time (priority asc, then skill id asc — spec rule 6).
---@param records table id -> record
---@return table slot -> table[] fragments
local function collect_fragments(records)
  local by_slot = {}
  for _, rec in pairs(records) do
    local frag = extract_fragment(rec)
    if frag then
      local bucket = by_slot[frag.slot]
      if not bucket then
        bucket = {}
        by_slot[frag.slot] = bucket
      end
      bucket[#bucket + 1] = frag
    end
  end
  return by_slot
end

---@param a table
---@param b table
---@return boolean
local function fragment_less(a, b)
  if a.priority ~= b.priority then
    return a.priority < b.priority
  end
  return a.id < b.id
end

--- Render one slot: sorted fragments joined with two newlines (spec rule 6);
--- a placeholder with no fragments renders empty (spec rule 8).
---@param frags table[]|nil
---@return string
local function render_slot(frags)
  if not frags or #frags == 0 then
    return ""
  end
  table.sort(frags, fragment_less)
  local parts = {}
  for _, f in ipairs(frags) do
    parts[#parts + 1] = trim(f.content)
  end
  return table.concat(parts, "\n\n")
end

--- Render the deterministic Skill table (`<skills_table>`): valid records only,
--- sorted by stable skill id.
---@param records table id -> record
---@return string
local function render_skills_table(records)
  local ids = {}
  for id, rec in pairs(records) do
    if rec.valid ~= false then
      ids[#ids + 1] = id
    end
  end
  table.sort(ids)
  local lines = { "| Skill | Name | Visibility |", "| --- | --- | --- |" }
  for _, id in ipairs(ids) do
    local rec = records[id]
    local md = rec.metadata or {}
    local name = type(md.name) == "string" and md.name or id
    local vis = type(md.visibility) == "string" and md.visibility or rec.root_kind or "local"
    local cell = name:gsub("%|", "\\|"):gsub("[\r\n]+", " ")
    lines[#lines + 1] = ("| %s | %s | %s |"):format(id, cell, vis)
  end
  return table.concat(lines, "\n")
end

--- Scan the working text for Skill slot placeholders.
---
--- Recognized grammar:
---   `<skill_system_prompt_fragments>`         -> slot "default"
---   `<skill_system_prompt_fragments:NAME>`    -> slot NAME ([A-Za-z0-9_-]+)
--- Anything else starting with the literal prefix is a malformed named slot
--- and blocks composition (spec rule 9). Literal angle-bracket text outside
--- the declared grammar is preserved.
---@param text string
---@return table|nil counts slot -> n
---@return table|nil err malformed-skill-slot-placeholder
local function scan_slot_placeholders(text)
  local counts = {}
  local pos = 1
  local prefix = "<skill_system_prompt_fragments"
  while true do
    local start = text:find(prefix, pos, true)
    if not start then
      break
    end
    local after = start + #prefix
    local next_char = text:sub(after, after)
    if next_char == ">" then
      counts[M.SLOT_DEFAULT] = (counts[M.SLOT_DEFAULT] or 0) + 1
      pos = after + 1
    elseif next_char == ":" then
      local close = text:find(">", after + 1, true)
      if not close then
        return nil, new_error(M.ERROR_KINDS.MALFORMED_SKILL_SLOT_PLACEHOLDER, "unterminated skill slot placeholder")
      end
      local name = text:sub(after + 1, close - 1)
      if not name:match(M.SLOT_PATTERN) then
        return nil,
          new_error(
            M.ERROR_KINDS.MALFORMED_SKILL_SLOT_PLACEHOLDER,
            ("malformed skill slot placeholder %q (expected [A-Za-z0-9_-]+)"):format(name)
          )
      end
      counts[name] = (counts[name] or 0) + 1
      pos = close + 1
    else
      -- Prefix without `:` or `>` (e.g. `<skill_system_prompt_fragmentsX>`):
      -- literal text outside the declared grammar, preserved.
      pos = start + #prefix
    end
  end
  return counts, nil
end

--- Replace every slot placeholder occurrence with its rendered content.
---@param text string
---@param rendered table slot -> string
---@return string
local function expand_slot_placeholders(text, rendered)
  local out = text
  for slot, content in pairs(rendered) do
    if slot == M.SLOT_DEFAULT then
      out = out:gsub("<skill_system_prompt_fragments>", content, 1)
    else
      out = out:gsub("<skill_system_prompt_fragments:" .. slot .. ">", content, 1)
    end
  end
  return out
end

--- Compose the final system prompt for a project snapshot.
---
---@param opts table { root=string, config?=table, skills_state?=table,
---   now?=string|number, machine?=string, vim_ver?=string }
---@return { system_prompt: string|nil, manifest: table, error: table|nil }
function M.compose(opts)
  opts = opts or {}
  local ctx, cerr = snapshot(opts)
  if cerr then
    return { system_prompt = nil, manifest = {}, error = cerr }
  end

  local bundled_path = M_ROOT .. "/" .. M.BUNDLED_REL
  local bundled_text, berr = read_text(bundled_path)
  if not bundled_text then
    return {
      system_prompt = nil,
      manifest = {},
      error = new_error(M.ERROR_KINDS.PROMPT_READ_ERROR, "bundled prompt: " .. berr),
    }
  end
  bundled_text = to_lf(bundled_text)

  local override_path = ctx.root .. "/" .. M.OVERRIDE_REL
  local override_text = nil
  if vim.fn.filereadable(override_path) == 1 then
    local text, oerr = read_text(override_path)
    if not text then
      return {
        system_prompt = nil,
        manifest = {},
        error = new_error(M.ERROR_KINDS.PROMPT_READ_ERROR, "project override: " .. oerr),
      }
    end
    override_text = to_lf(text)
  end
  local used_fallback = override_text == nil

  -- Expand `<system_prompt>` first (spec rule 3): override wrapper must carry
  -- exactly one placeholder; bundled full text is injected there.
  local working = override_text or bundled_text
  if override_text then
    local _, n = override_text:gsub("<system_prompt>", "")
    if n == 0 then
      return {
        system_prompt = nil,
        manifest = {},
        error = new_error(
          M.ERROR_KINDS.MISSING_SYSTEM_PROMPT_PLACEHOLDER,
          ("project %s must contain exactly one <system_prompt> placeholder"):format(override_path)
        ),
      }
    end
    if n > 1 then
      return {
        system_prompt = nil,
        manifest = {},
        error = new_error(
          M.ERROR_KINDS.DUPLICATE_SYSTEM_PROMPT_PLACEHOLDER,
          ("project %s contains %d <system_prompt> placeholders (exactly one required)"):format(override_path, n)
        ),
      }
    end
    working = override_text:gsub("<system_prompt>", bundled_text, 1)
  end

  -- Skill fragments from the discovery state (synthetic in tests).
  local records = normalize_records(opts.skills_state)
  local by_slot = collect_fragments(records)

  -- Slot placeholder validation (spec rules 7/8/9).
  local counts, serr = scan_slot_placeholders(working)
  if serr then
    return { system_prompt = nil, manifest = {}, error = serr }
  end
  local duplicate_slot
  for slot, n in pairs(counts) do
    if n > 1 then
      duplicate_slot = slot
      break
    end
  end
  if duplicate_slot then
    return {
      system_prompt = nil,
      manifest = {},
      error = new_error(
        M.ERROR_KINDS.DUPLICATE_SKILL_SLOT_PLACEHOLDER,
        ("skill slot placeholder %q appears %d times (at most once per slot)"):format(
          duplicate_slot,
          counts[duplicate_slot]
        )
      ),
    }
  end
  for slot in pairs(by_slot) do
    if slot ~= M.SLOT_DEFAULT and not counts[slot] then
      return {
        system_prompt = nil,
        manifest = {},
        error = new_error(
          M.ERROR_KINDS.UNBOUND_SKILL_SYSTEM_SLOT,
          ("declared skill system slot %q has no matching placeholder in the prompt template"):format(slot)
        ),
      }
    end
  end

  -- Render and inject fragments (deterministic per slot), then scalars.
  -- Every placeholder found in the template renders (empty when the slot has
  -- no fragments — spec rule 8).
  local rendered = {}
  for slot in pairs(counts) do
    rendered[slot] = ""
  end
  local manifest_frags = {}
  for slot, frags in pairs(by_slot) do
    table.sort(frags, fragment_less)
    rendered[slot] = render_slot(frags)
    for _, f in ipairs(frags) do
      manifest_frags[#manifest_frags + 1] = {
        id = f.id,
        path = f.path,
        slot = f.slot,
        priority = f.priority,
        hash = fnv1a_hex(trim(f.content)),
      }
    end
  end
  table.sort(manifest_frags, function(a, b)
    if a.slot ~= b.slot then
      return a.slot < b.slot
    end
    if a.priority ~= b.priority then
      return a.priority < b.priority
    end
    return a.id < b.id
  end)

  working = expand_slot_placeholders(working, rendered)
  working = working:gsub("<date>", ctx.date)
  working = working:gsub("<vim_ver>", ctx.vim_ver)
  working = working:gsub("<machine>", ctx.machine)
  working = working:gsub("<root_dir>", ctx.root)
  working = working:gsub("<skills_table>", render_skills_table(records))
  working = to_lf(working)

  local skills_table_count = 0
  for id, rec in pairs(records) do
    if rec.valid ~= false then
      skills_table_count = skills_table_count + 1
    end
  end

  local manifest = {
    bundled_path = bundled_path,
    override_path = override_text and override_path or nil,
    used_fallback = used_fallback,
    root_dir = ctx.root,
    date = ctx.date,
    vim_ver = ctx.vim_ver,
    machine = ctx.machine,
    skills_table_count = skills_table_count,
    fragments = manifest_frags,
    sources = {
      { kind = "bundled", path = bundled_path },
    },
  }
  if override_text then
    manifest.sources[#manifest.sources + 1] = { kind = "override", path = override_path }
  end

  return { system_prompt = working, manifest = manifest, error = nil }
end

--- Same pipeline as compose(); adds a redacted source manifest. Never changes
--- the composed output. Sources contain paths/hashes only — no secrets.
---@param opts table same as compose()
---@return { system_prompt: string|nil, manifest: table, sources: table, redacted: boolean, error: table|nil }
function M.dump(opts)
  local result = M.compose(opts)
  result.sources = result.manifest and result.manifest.sources or {}
  result.redacted = true
  return result
end

return M
