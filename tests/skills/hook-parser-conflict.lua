-- filepath: tests/skills/hook-parser-conflict.lua
--- Phase-3 W6 fixture: hook parser validation.
---   * md+lua definitions for one event are a validation error and the event
---     is skipped (downstream scan_hooks conflict semantics);
---   * enabled=false hooks are skipped without error;
---   * definition_hash is deterministic over the normalized definition (same
---     content -> same hash; changed content -> different hash);
---   * invalid frontmatter fields fail closed with typed parse errors.
---
--- Fixture convention: prints HOOK_PARSER_CONFLICT_OK on success; throws on
--- failure.
local assert_mod = require("tests.state.lib.assert")
local harness = require("tests.skills.lib.harness")
local A = assert_mod.new()
local h = harness.new()

local parser = require("maxa.runtime.skills.parser")

-------------------------------------------------------------------------------
-- Fixture tree
-------------------------------------------------------------------------------
-- A. Conflict: same event in both formats -> skipped event + error entry.
h.write_skill(h.project_root, "conflict", { name = "conflict", description = "conflict hook fixture" }, "BODY")
h.write_hook_md(h.project_root, "conflict", "ChatSubmitted", { inject_at = "pre" }, "## user\n\nHELLO FROM MD\n")
h.write_hook_lua(
  h.project_root,
  "conflict",
  "ChatSubmitted",
  [[return { load = "on_load", scope = "global", inject_at = "pre", render = function(ctx) return nil end }]]
)

-- B. enabled=false md hook is skipped silently.
h.write_skill(h.project_root, "disabled", { name = "disabled", description = "disabled hook fixture" }, "BODY")
h.write_hook_md(
  h.project_root,
  "disabled",
  "ResponseCompleted",
  { enabled = false, inject_at = "post" },
  "## system\n\nNEVER\n"
)

-- C. Hash determinism: two identical md hooks (different skills) hash equal;
-- a modified body hashes differently.
h.write_skill(h.project_root, "hash-a", { name = "hash-a", description = "hash fixture a" }, "BODY")
h.write_skill(h.project_root, "hash-b", { name = "hash-b", description = "hash fixture b" }, "BODY")
h.write_hook_md(h.project_root, "hash-a", "ChatSubmitted", { inject_at = "pre" }, "## user\n\nSAME PROMPT\n")
h.write_hook_md(h.project_root, "hash-b", "ChatSubmitted", { inject_at = "pre" }, "## user\n\nSAME PROMPT\n")
h.write_hook_md(h.project_root, "hash-a", "ResponseCompleted", { inject_at = "post" }, "## user\n\nDIFFERENT PROMPT\n")

-- D. Invalid frontmatter fails closed.
h.write_skill(h.project_root, "bad-load", { name = "bad-load", description = "bad load fixture" }, "BODY")
h.write_hook_md(h.project_root, "bad-load", "ChatSubmitted", { load = "never", inject_at = "pre" }, "## user\n\nX\n")

-------------------------------------------------------------------------------
-- A. md+lua conflict
-------------------------------------------------------------------------------
do
  local scanned = parser.scan_hooks(h.skill_dir(h.project_root, "conflict"), "conflict")
  A.assert_eq(#scanned.hooks, 0, "conflict: no hook registered for conflicting event")
  A.assert_eq(#scanned.errors, 1, "conflict: exactly one error entry")
  if scanned.errors[1] then
    A.assert_eq(scanned.errors[1].reason, "conflict", "conflict: error reason")
    A.assert_eq(scanned.errors[1].event_name, "ChatSubmitted", "conflict: error event name")
    A.check(scanned.errors[1].files.md ~= nil and scanned.errors[1].files.lua ~= nil, "conflict: both files reported")
  end
end

-------------------------------------------------------------------------------
-- B. enabled=false skip
-------------------------------------------------------------------------------
do
  local scanned = parser.scan_hooks(h.skill_dir(h.project_root, "disabled"), "disabled")
  A.assert_eq(#scanned.hooks, 0, "disabled: no hook registered")
  A.assert_eq(#scanned.errors, 0, "disabled: no error entry")
end

-------------------------------------------------------------------------------
-- C. definition hash determinism
-------------------------------------------------------------------------------
do
  local a1 = parser.scan_hooks(h.skill_dir(h.project_root, "hash-a"), "hash-a").hooks
  local b1 = parser.scan_hooks(h.skill_dir(h.project_root, "hash-b"), "hash-b").hooks
  local by_event = {}
  for _, hook in ipairs(a1) do
    by_event[hook.event_name] = hook
  end
  local ha_chat = by_event["ChatSubmitted"]
  local ha_resp = by_event["ResponseCompleted"]
  local hb_chat = nil
  for _, hook in ipairs(b1) do
    if hook.event_name == "ChatSubmitted" then
      hb_chat = hook
    end
  end
  A.check(ha_chat ~= nil and ha_resp ~= nil and hb_chat ~= nil, "hash: all hooks parsed")
  if ha_chat and hb_chat then
    A.assert_eq(ha_chat.definition_hash, hb_chat.definition_hash, "hash: identical definitions hash equal")
  end
  if ha_chat and ha_resp then
    A.check(ha_chat.definition_hash ~= ha_resp.definition_hash, "hash: different definitions hash differently")
  end
  if ha_chat then
    A.check(type(ha_chat.definition_hash) == "string" and #ha_chat.definition_hash > 0, "hash: non-empty hash string")
    -- Deterministic across parses of the same file.
    local reparsed = parser.scan_hooks(h.skill_dir(h.project_root, "hash-a"), "hash-a").hooks
    for _, hook in ipairs(reparsed) do
      if hook.event_name == "ChatSubmitted" then
        A.assert_eq(hook.definition_hash, ha_chat.definition_hash, "hash: stable across reparses")
      end
    end
  end
end

-------------------------------------------------------------------------------
-- D. invalid frontmatter fails closed
-------------------------------------------------------------------------------
do
  local scanned = parser.scan_hooks(h.skill_dir(h.project_root, "bad-load"), "bad-load")
  A.assert_eq(#scanned.hooks, 0, "bad-load: no hook registered")
  A.assert_eq(#scanned.errors, 1, "bad-load: one parse error")
  if scanned.errors[1] then
    A.assert_eq(scanned.errors[1].reason, "parse", "bad-load: error reason")
    A.check(scanned.errors[1].message:find("load", 1, true) ~= nil, "bad-load: message mentions load")
  end
end

if not A.ok then
  error("hook-parser-conflict FAILED", 0)
end
h.cleanup()
print("HOOK_PARSER_CONFLICT_OK")
