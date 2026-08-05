-- filepath: tests/skills/hook-filter.lua
--- Phase-3 W6 fixture: pure payload filters.
---   * markdown filter tables: fields AND, `a|b` OR, `!` negation, `prefix:`,
---     `*` existence; no-match => no injection and no render call;
---   * lua function filters run with the hook ctx; a false return blocks
---     render entirely (no-match behavior is explicit);
---   * empty/nil filters always match.
---
--- Fixture convention: prints HOOK_FILTER_OK on success; throws on failure.
local assert_mod = require("tests.state.lib.assert")
local harness = require("tests.skills.lib.harness")
local A = assert_mod.new()
local h = harness.new()

local skills = require("maxa.runtime.skills")

_G.hook_filter_fixture = { calls = 0 }

-------------------------------------------------------------------------------
-- Fixture tree
-------------------------------------------------------------------------------
h.write_skill(h.project_root, "filter-md", { name = "filter-md", description = "md filter" }, "BODY")
h.write_hook_md(
  h.project_root,
  "filter-md",
  "ChatSubmitted",
  { load = "startup", scope = "global", inject_at = "pre", filter = { kind = "user" } },
  "## user\n\nMD FILTERED PROMPT\n"
)
h.write_skill(h.project_root, "filter-lua", { name = "filter-lua", description = "lua filter" }, "BODY")
h.write_hook_lua(
  h.project_root,
  "filter-lua",
  "ChatSubmitted",
  [[
return {
  load = "startup",
  scope = "global",
  inject_at = "pre",
  filter = function(ctx)
    return ctx.data.text ~= "skip"
  end,
  render = function(ctx)
    _G.hook_filter_fixture.calls = _G.hook_filter_fixture.calls + 1
    return { { role = "user", content = "LUA FILTERED PROMPT" } }
  end,
}
]]
)
h.write_skill(h.project_root, "filter-or", { name = "filter-or", description = "or filter" }, "BODY")
h.write_hook_md(
  h.project_root,
  "filter-or",
  "ChatSubmitted",
  { load = "startup", scope = "global", inject_at = "pre", filter = { channel = "a|b" } },
  "## user\n\nOR FILTERED PROMPT\n"
)
h.write_skill(h.project_root, "filter-neg", { name = "filter-neg", description = "negation filter" }, "BODY")
h.write_hook_md(
  h.project_root,
  "filter-neg",
  "ChatSubmitted",
  { load = "startup", scope = "global", inject_at = "pre", filter = { source = "!internal" } },
  "## user\n\nNEG FILTERED PROMPT\n"
)

local d = h.discover()
d.scan()
local env = h.hook_env()
skills.setup_startup_hooks({ discover = d, registry = env.registry })

local function fire_payload(extra)
  local payload = { session_id = "s1", kind = "user", text = "go", source = "user", channel = "a" }
  for k, v in pairs(extra or {}) do
    payload[k] = v
  end
  return env.fire.pre("ChatSubmitted", payload, { stack = env.stack })
end

-------------------------------------------------------------------------------
-- A. exact match: every filter matches the full payload
-------------------------------------------------------------------------------
do
  local res = fire_payload()
  A.check(res.ok, "filter: all-match dispatch ok")
  A.assert_eq(res.injected, 4, "filter: md+lua+or+neg all inject")
  A.assert_eq(_G.hook_filter_fixture.calls, 1, "filter: lua render called once")
end

-------------------------------------------------------------------------------
-- B. md filter no-match: kind != user
-------------------------------------------------------------------------------
do
  local res = fire_payload({ kind = "agent" })
  A.check(res.ok, "filter: kind no-match dispatch ok")
  A.assert_eq(res.injected, 3, "filter: only the md filter blocks")
  A.assert_eq(res.skipped, 1, "filter: md no-match skipped")
end

-------------------------------------------------------------------------------
-- C. lua function filter no-match: render NOT called
-------------------------------------------------------------------------------
do
  local before = _G.hook_filter_fixture.calls
  local res = fire_payload({ text = "skip" })
  A.check(res.ok, "filter: lua block dispatch ok")
  A.assert_eq(res.injected, 3, "filter: only the lua filter blocks")
  A.assert_eq(_G.hook_filter_fixture.calls, before, "filter: render NOT called on filter no-match")
end

-------------------------------------------------------------------------------
-- D. OR no-match and negation no-match
-------------------------------------------------------------------------------
do
  local or_miss = fire_payload({ channel = "c" })
  A.check(or_miss.ok, "filter: or no-match dispatch ok")
  A.assert_eq(or_miss.injected, 3, "filter: OR filter blocks channel c")

  local neg_miss = fire_payload({ source = "internal" })
  A.check(neg_miss.ok, "filter: negation no-match dispatch ok")
  A.assert_eq(neg_miss.injected, 3, "filter: negation filter blocks internal source")
  A.assert_eq(_G.hook_filter_fixture.calls, 4, "filter: render ran for every lua pass (A, B, D, D)")
end

-------------------------------------------------------------------------------
-- E. raw predicate helper parity (fire.matches_filter)
-------------------------------------------------------------------------------
do
  local fire_mod = require("maxa.runtime.skills.fire")
  A.check(
    fire_mod.matches_filter({ tool_id = "prefix:mcpx__" }, { tool_id = "mcpx__load_skill" }),
    "filter: prefix match"
  )
  A.check(not fire_mod.matches_filter({ tool_id = "prefix:mcpx__" }, { tool_id = "other" }), "filter: prefix no-match")
  A.check(fire_mod.matches_filter(nil, {}), "filter: nil filter matches")
  A.check(fire_mod.matches_filter({}, {}), "filter: empty filter matches")
  A.check(fire_mod.matches_filter({ tag = "*" }, { tag = "x" }), "filter: existence match")
  A.check(not fire_mod.matches_filter({ tag = "*" }, {}), "filter: existence no-match")
end

if not A.ok then
  error("hook-filter FAILED", 0)
end
h.cleanup()
_G.hook_filter_fixture = nil
print("HOOK_FILTER_OK")
