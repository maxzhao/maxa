-- filepath: tests/prompts/integration.lua
--- W5 C-* integration: real config (config.configure(M.defaults, opts)) +
--- the runtime prompt composer + state classification.
---
--- Covers (supermax-configuration spec §Prompt composition / §Runtime defaults):
---   C-001  no project `.maxa/system.md` -> bundled runtime prompt fallback
---          (used_fallback=true; composed prompt carries the runtime contract);
---   C-002  project override wrapper expands `<system_prompt>` exactly once and
---          the development `.supermax/` content is NEVER a prompt source
---          (not even when `.supermax/system.md` exists);
---   C-003  composition slot errors: a declared skill system slot without a
---          matching placeholder blocks composition (unbound-skill-system-slot),
---          and a project wrapper without `<system_prompt>` blocks with
---          missing-system-prompt-placeholder;
---   C-004  `.maxa/state.yaml` schema_version classification through the real
---          config module (ok / project-upgrade-required /
---          runtime-upgrade-required / project-version-invalid /
---          runtime-version-unavailable / not-initialized).
---
--- Offline; no network, no key. Exit contract: returns true on success; the
--- caller turns a false/error into `:cq`.
local ok_all = true
local failures = {}
local function check(cond, msg)
  if not cond then
    ok_all = false
    failures[#failures + 1] = msg
    print("VERIFY_FAIL: " .. msg)
  end
end
local function assert_eq(got, want, msg)
  if got ~= want then
    check(false, ("%s (got %s, want %s)"):format(msg, vim.inspect(got), vim.inspect(want)))
  end
end
local function ensure_ecosystem()
  local ok, _ = pcall(require, "plenary.path")
  if not ok then
    error("tests/prompts/integration.lua: plenary.path not require-able (LazyVim ecosystem missing)")
  end
end
ensure_ecosystem()
local config = require("maxa.runtime.config")
local prompts = require("maxa.runtime.prompts")
local maxa_mod = require("maxa")

--- Create an isolated temp project root with a `.maxa/` directory.
local function mk_root()
  local root = vim.fn.tempname()
  vim.fn.mkdir(root .. "/.maxa", "p")
  return root
end

--- Write a text file (creates parent directories).
local function write_text(path, content)
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  local fh = assert(io.open(path, "wb"))
  fh:write(content)
  fh:close()
end

--- Real-config snapshot: effective tree produced by config.configure over the
--- real defaults (the same path maxa.setup uses), then compose with it.
---@param root string project root
---@param skills_state? table|nil skills discovery state
---@param override? string|nil `.maxa/system.md` body (nil = absent)
---@return table compose result
local function compose_with_real_config(root, skills_state, override)
  if override ~= nil then
    write_text(root .. "/.maxa/system.md", override)
  end
  local cfg, cerr = config.configure(maxa_mod.defaults, {})
  check(cfg ~= nil, "real config configure ok (err=" .. tostring(cerr and cerr.message) .. ")")
  return prompts.compose({
    root = root,
    config = cfg,
    skills_state = skills_state,
  })
end

------------------------------------------------------------
-- C-001: no project .maxa/system.md -> bundled fallback
------------------------------------------------------------
do
  local root = mk_root()
  local res = compose_with_real_config(root, nil, nil)
  check(res.error == nil, "C-001: compose ok (err=" .. tostring(res.error and res.error.message) .. ")")
  check(type(res.system_prompt) == "string" and res.system_prompt ~= "", "C-001: system_prompt produced")
  check(res.manifest.used_fallback == true, "C-001: used_fallback == true (no project wrapper)")
  if type(res.system_prompt) == "string" then
    check(
      res.system_prompt:find("maxa runtime system contract", 1, true) ~= nil,
      "C-001: bundled runtime contract content present"
    )
    check(res.system_prompt:find("<root_dir>", 1, true) == nil, "C-001: scalar placeholders expanded")
    check(res.system_prompt:find(root, 1, true) ~= nil, "C-001: <root_dir> expanded to the bound project root")
  end
end

------------------------------------------------------------
-- C-002: override wrapper expands <system_prompt>; .supermax ignored
------------------------------------------------------------
do
  local root = mk_root()
  -- A development-mother-repo style `.supermax/system.md` must NEVER become a
  -- prompt source for the runtime.
  write_text(root .. "/.supermax/system.md", "SUPERMAX-MUST-NOT-APPEAR\n<system_prompt>\n")
  local res = compose_with_real_config(root, nil, "# Project rules\n<system_prompt>\nPROJECT-OVERRIDE-MARKER\n")
  check(res.error == nil, "C-002: compose ok (err=" .. tostring(res.error and res.error.message) .. ")")
  check(res.manifest.used_fallback == false, "C-002: used_fallback == false (override used)")
  check(res.manifest.override_path ~= nil, "C-002: manifest.override_path recorded")
  if type(res.system_prompt) == "string" then
    check(res.system_prompt:find("PROJECT-OVERRIDE-MARKER", 1, true) ~= nil, "C-002: override content present")
    -- The wrapper's `<system_prompt>` placeholder was expanded exactly once; the
    -- bundled contract mentions `<system_prompt>` once in its own descriptive
    -- text, so the composed prompt must contain it exactly that many times
    -- (a second wrapper placeholder would have failed with duplicate errors).
    local _, n = res.system_prompt:gsub("<system_prompt>", "")
    assert_eq(n, 1, "C-002: wrapper placeholder expanded exactly once (bundled mentions only)")
    check(
      res.system_prompt:find("SUPERMAX-MUST-NOT-APPEAR", 1, true) == nil,
      "C-002: .supermax/system.md never injected"
    )
    check(
      res.system_prompt:find("maxa runtime system contract", 1, true) ~= nil,
      "C-002: bundled contract still present inside the wrapper"
    )
  end
end

------------------------------------------------------------
-- C-003: composition slot errors
------------------------------------------------------------
do
  -- 3a. Declared skill system slot without a matching placeholder -> typed error.
  local root = mk_root()
  local skills_state = {
    records = {
      ["demo-skill"] = {
        id = "demo-skill",
        root_kind = "bundled", -- global fragment (eligible)
        valid = true,
        file = root .. "/skills/demo/SKILL.md",
        metadata = {
          name = "demo",
          system = { slot = "slot-a", content = "DEMO FRAGMENT" },
        },
      },
    },
  }
  local res = compose_with_real_config(root, skills_state, nil)
  check(res.system_prompt == nil, "C-003a: unbound slot blocks composition")
  check(
    res.error ~= nil and res.error.kind == prompts.ERROR_KINDS.UNBOUND_SKILL_SYSTEM_SLOT,
    "C-003a: error kind unbound-skill-system-slot (got " .. tostring(res.error and res.error.kind) .. ")"
  )

  -- 3b. Project wrapper without <system_prompt> -> typed error (never replaces
  -- the runtime contract silently).
  local root2 = mk_root()
  local res2 = compose_with_real_config(root2, nil, "# No placeholder here\n")
  check(res2.system_prompt == nil, "C-003b: missing placeholder blocks composition")
  check(
    res2.error ~= nil and res2.error.kind == prompts.ERROR_KINDS.MISSING_SYSTEM_PROMPT_PLACEHOLDER,
    "C-003b: error kind missing-system-prompt-placeholder (got " .. tostring(res2.error and res2.error.kind) .. ")"
  )
end

------------------------------------------------------------
-- C-004: state.yaml schema_version classification (real config module)
------------------------------------------------------------
do
  local root = mk_root()
  -- 4a. Missing state file = not initialized (never an error).
  local cls, cerr = config.classify_state(root)
  check(cerr == nil, "C-004a: classify missing state ok (err=" .. tostring(cerr and cerr.message) .. ")")
  check(cls ~= nil and cls.status == "not-initialized", "C-004a: status not-initialized")

  -- 4b. schema_version == runtime -> ok.
  local p1, e1 = config.save_state(root, { schema_version = config.STATE_SCHEMA_VERSION, project_id = "c004" })
  check(p1 ~= nil, "C-004b: save_state ok (err=" .. tostring(e1 and e1.message) .. ")")
  local cls1, cerr1 = config.classify_state(root)
  check(cls1 ~= nil and cls1.status == "ok", "C-004b: status ok (got " .. tostring(cls1 and cls1.status) .. ")")
  assert_eq(cls1 and cls1.schema_version, config.STATE_SCHEMA_VERSION, "C-004b: schema_version carried")

  -- 4c. Older project schema -> project-upgrade-required.
  local root2 = mk_root()
  config.save_state(root2, { schema_version = 0, project_id = "c004-old" })
  local cls2, cerr2 = config.classify_state(root2)
  check(cerr2 == nil and cls2 and cls2.status == "project-upgrade-required", "C-004c: status project-upgrade-required")

  -- 4d. Newer project schema (runtime is older) -> runtime-upgrade-required.
  local root3 = mk_root()
  config.save_state(root3, { schema_version = config.STATE_SCHEMA_VERSION + 1, project_id = "c004-new" })
  local cls3, cerr3 = config.classify_state(root3)
  check(cerr3 == nil and cls3 and cls3.status == "runtime-upgrade-required", "C-004d: status runtime-upgrade-required")

  -- 4e. Invalid schema_version -> project-version-invalid.
  local root4 = mk_root()
  config.save_state(root4, { schema_version = "abc", project_id = "c004-bad" })
  local cls4, cerr4 = config.classify_state(root4)
  check(cerr4 == nil and cls4 and cls4.status == "project-version-invalid", "C-004e: status project-version-invalid")

  -- 4f. Unavailable runtime version (explicit false sentinel) ->
  -- runtime-version-unavailable.
  local root5 = mk_root()
  config.save_state(root5, { schema_version = 1, project_id = "c004-rv" })
  local cls5, cerr5 = config.classify_state(root5, false)
  check(
    cerr5 == nil and cls5 and cls5.status == "runtime-version-unavailable",
    "C-004f: status runtime-version-unavailable"
  )

  -- 4g. Non-mapping state body (decodes to a scalar, not a mapping) -> typed
  -- CONFIGURATION error through load_state; never silently classified.
  local root6 = mk_root()
  write_text(root6 .. "/.maxa/state.yaml", "just-a-string\n")
  local cls6, cerr6 = config.classify_state(root6)
  check(
    cls6 == nil and cerr6 ~= nil,
    "C-004g: non-mapping state.yaml surfaces typed error (got " .. tostring(cls6 and cls6.status) .. ")"
  )
end

if ok_all then
  print("PROMPTS_INTEGRATION_OK")
else
  print("PROMPTS_INTEGRATION_FAILED count=" .. #failures)
  vim.cmd("cq")
end
return ok_all
