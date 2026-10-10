# Ability SYSTEM.md Fragment Authoring Guide

Use this guide when writing or reviewing an Ability root `SYSTEM.md`. It defines the general contract for system prompt fragments, not one Ability's behavior.

## Positioning

`SYSTEM.md` is not loaded by `load`. It is scanned during system prompt generation, sorted by slot/priority, and inserted into `prompts/system.md`.

Write it as an embedded fragment, not a standalone document. Quality test: after insertion, the final dumped system prompt has clear structure, correct heading hierarchy, correct slot placement, and reasonable ordering.

Appropriate content:

- Routing rules needed before ordinary Ability Gate.
- Minimal entry rules for mandatory workflows/protocols.
- Non-skippable safety constraints or hard tool-use rules.
- Stable governance rules active across sessions.

Inappropriate content:

- Long tutorials, full manuals, many examples.
- Workflow details loadable on demand.
- Reference material, exhaustive script arguments, variant catalogs.
- Local temporary preferences, one-off debugging, private project conventions.

Put inappropriate content in `SKILL.md`, `references/`, `scripts/`, or project rules.

## Frontmatter

Minimal format:

```markdown
---
allow_non_global: true
slot: execution
priority: 100
---
```

Field rules:

- `allow_non_global`: required when the effective Ability visibility is not `global`; global Abilities may omit it.
- `slot`: insertion point name; default `default`. Main system prompt must contain `<ability_system_prompt_fragments:slot>`; `default` uses `<ability_system_prompt_fragments>`.
- `priority`: ordering within the same slot; default `100`; lower appears earlier.
- Do not use AbilityHook fields: `load`, `scope`, `filter`, `opts`, `inject_at`.

## Slot Selection

Choose the slot by primary behavior change; use priority only for order inside that slot.

| Slot | Purpose | Examples |
| --- | --- | --- |
| `context_management` | Tokens, compression, temporary context, history | Session compression, TTL result handling |
| `execution` | Task protocols, delegation, human assist, mandatory workflow entrypoints | TaskAdmin, SubAgent, Human Assist |
| `tool_usage` | Tool-call protocols, complex parameters, MCP hard rules | Justfile, web fetching |
| `capabilities` | Capability routing and discovery supplements | Non-global Ability index |
| `default` | Compatibility fallback | Use only as fallback |

Decision shortcuts:

- Changes when to enter workflow -> `execution`.
- Changes how to call tools -> `tool_usage`.
- Changes how to preserve/compress context -> `context_management`.
- Changes how to discover capabilities -> `capabilities`.

## Priority Design

Rules:

- Lower numbers appear earlier.
- If order has semantic meaning, use different priorities.
- Do not rely on Ability directory names, scan order, or equal-priority ordering.
- Leave gaps such as `10 / 20 / 40 / 60 / 80`.

Common ordering: basic/general before specific; rules affecting later tool calls earlier; safety/mandatory constraints before explanatory rules.

Example:

```markdown
---
slot: tool_usage
priority: 10
---

#### Example Tool Protocol
```

## Heading Hierarchy

Fragments are inserted under host sections, usually `###`.

Rules:

- Top-level fragment heading should usually be `####`.
- Subsections continue with `#####` / `######`.
- Unless the slot has no host section, do not use `##` or `###` in fragment body.
- Markdown examples inside fenced code blocks are exempt.

Recommended:

```markdown
#### Task Execution Guard

##### Trigger Conditions

##### Required Steps
```

Avoid:

```markdown
### Task Execution Guard

#### Trigger Conditions
```

## Content Granularity

Every line becomes always-on prompt text. Minimize it.

Recommended content:

1. Trigger/recognition rules.
2. Which Ability must load first.
3. Non-skippable constraints.
4. Shortest necessary execution order.
5. Safe fallback when blocked.

Avoid:

- Full reference content.
- Long background explanations.
- Long tables or code examples.
- Ordinary operation steps available after Ability loading.
- Local paths, temporary commands, or project-specific preferences.

Decision question: must this rule apply before the Ability can be loaded? If it can safely take effect after loading but before the first relevant action, prefer `SKILL.md` or a scenario reference. Do not demote safety, identity, or ownership boundaries required before loading.

## Normative Ownership And Migration

- Keep one normative definition for each behavior. The host prompt and an inserted fragment must not separately maintain a complete protocol; retain one owner and route to it.
- Preserve required behavior and authority when moving text. An optional reference is not a replacement for an enforced pre-load boundary.
- In the destination Ability, route the moved workflow before its first governed action. A Resources listing alone is not a load guarantee; do not compensate by requiring every task to read all handbooks.
- Inspect indirect sources that can reintroduce retired instructions: wrappers, project overrides, templates, examples, role files, hooks, and script output, where affected by the change.
- Review the generated contract for conflicting strength and stopping behavior, not just heading placement. Generic autonomy and approval semantics belong to `prompt-engineering`; load and follow that Ability rather than copying its definitions.

Use `references/ability-routing-and-disclosure.md` when the change also affects Ability selection or resource layout.

## No Debug Artifacts

Do not include source comments, debug markers, or generator internals such as:

```markdown
<!-- skill-system-prompt: xxx slot=tool_usage priority=70 -->
```

Use generator debug mode, external dumps, or development logs for source tracing instead.

## Language And Tone

Use stable, explicit, executable rules.

Prefer:

- Imperative or constraint language.
- Clear “must / must not / only when / default”.
- Short exceptional-path handling.
- General terms over local temporary preferences.

Avoid:

- Historical explanation.
- Vague hard rules such as “preferably”.
- Current-machine/project accidents as shared contracts.
- Conflicts with main system prompt, tool safety, or higher-priority project rules.

## Cross-Project Compatibility

Shared `SYSTEM.md` affects downstream Agents. Before writing, check:

- Does default behavior remain compatible?
- Are old interfaces, tool names, and workflows preserved?
- Does it hold outside the current directory?
- Is local-only logic isolated into project rules/local docs?
- If a service/tool/file is missing, does behavior degrade gracefully?
- No local temporary preferences, absolute private paths, or credentials are included.

## Validation Workflow

After modifying `SYSTEM.md`, check the final generated system prompt.

Validation scope:

- Generate the final prompt through the actual builder. Inspect the heading tree, slot placement, priority ordering, unresolved placeholders, debug comments, and abnormal blank lines.
- Check that each protocol has one normative owner and that migrated constraints still apply before governed actions. Compare safety, identity, ownership, and acceptance boundaries, including “prefer” versus “must” conflicts.
- Exercise affected project overrides, wrapper templates, and non-global fragment inclusion when the change touches those paths. Preserve public generation behavior; no full environment matrix is required for unrelated wording edits.
- Run Ability package lint and closest relevant builder/loader checks. Prefer structural/interface regression coverage over exact ordinary-sentence assertions.
- Distinguish static generated-contract review, actual integration checks, and model-behavior trials. A correct dump is not proof of fewer pauses or more accurate selection; disclose material untested behavior.

Reuse valid checks and repeat only when changes, failures, unresolved concerns, or explicit requirements warrant it. If a required boundary is lost, repair the migration rather than delete the boundary to pass validation.

Heading checks:

- Fragment appears under correct host section.
- Fragment top heading is `####`.
- Internal subsections use lower heading levels.
- No unexpected `##` / `###` competes with main structure.

## Review Checklist

- [ ] Rule must be always-on before Ability loading.
- [ ] Content is minimal entry rule, not tutorial/manual.
- [ ] Slot is semantically correct.
- [ ] Priority expresses order without accidental ordering.
- [ ] Top heading uses `####` with valid nested headings.
- [ ] No debug/source/generator internals.
- [ ] No local temporary preferences, absolute paths, or credentials.
- [ ] No conflict with main system prompt or higher-priority rules.
- [ ] One normative owner remains; authority and pre-action load timing survive migration across affected wrapper, override, non-global, and indirect execution paths.
- [ ] Final dump generated and heading tree checked.
- [ ] Relevant lint, syntax check, or project validation ran.
