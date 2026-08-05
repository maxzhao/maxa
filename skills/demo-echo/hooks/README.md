# demo-echo hooks/ sample

This directory demonstrates the W6 SkillHook layout for the `demo-echo` demo
Skill. It is intentionally EMPTY of active hook definitions in W5:

- W5 discovery/loading treats hook files as declared metadata only and never
  executes them.
- W6 (`skills/parser.lua`) will define the active formats:
  - `hooks/{EventName}.md` — Markdown hook with frontmatter
    (`enabled/load/scope/filter/opts/inject_at/once`) and
    `## user/## llm/## system` prompt sections;
  - `hooks/{EventName}.lua` — Lua hook returning a hook table
    `{ load, scope, inject_at, enabled, opts, render }`.
- A Markdown and a Lua hook for the SAME event in the same Skill is a
  validation error (conflicting definitions).

The `demo-echo` Skill declares no hooks (`hooks: []` in SKILL.md); it exists to
validate the mechanism, not to exercise it.
