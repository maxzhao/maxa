---
title: Command Prompt Contracts 行为规格
created: 2026-06-29
updated: 2026-10-09
type: source
doc_role: spec
authority: accepted
status: active
capability: command-prompt-contracts
sources:
  - prompts/commands/
  - lua/maxa/prompts/sources.lua
  - abilities/prompt-engineering/SKILL.md
confidence: medium
review:
  human: passed
  evidence: user-declared-change-review-2026-10-07
validation:
  runtime_invocation: not-run
---

### Scope

Owns reusable Maxa AI prompt-library contracts and active/deprecated boundaries for `prompts/commands/`, excluding TaskAdmin plan/TODO. [Markdown Prompt format](./markdown-format.md) owns role/slash syntax; [Runtime plugin entrypoints](../runtime/plugin-entrypoints.md) owns registration.

### Requirements

#### Requirement: Active command prompts are executable contracts

Each active Markdown command prompt SHALL define a proportionate goal, inputs/dynamic context, required tools or capability routing, workflow/dependencies, expected output, failure handling, validation and completion boundary. It SHALL separate stable instructions from user input/examples/retrieved text; lower-authority content SHALL NOT override runtime safety/tool rules. It SHALL NOT embed one-off progress, private absolute paths, credentials, raw logs or mutable local preferences.

Prompts SHALL request internal reasoning only when the output consumer needs it, and SHALL NOT require chain-of-thought, confidence scores, self-grading or speculative multi-agent work. Missing skill/tool/caller dependencies SHALL be reported exactly, without invented schemas.

#### Requirement: Runtime discoverability is preserved

Active repository prompts SHALL remain discoverable at fixed `prompts/commands/`; project-local lookup stays separate at `<project>/.maxa/prompts/`. Runtime fixed-source discovery owns registration, not configurable prompt directories in `lua/plugins/ai.lua`. Moves/renames SHALL update actual caller references before deleting old paths; deprecated subdirectories SHALL NOT be scanned automatically.

#### Requirement: Active TaskAdmin command identities follow the single-level model

Active TaskAdmin commands SHALL follow these contracts and SHALL NOT reintroduce parent/subtask, progress-sidecar or forced SubAgent semantics:

- `create_task`: create one complete TaskAdmin workspace; active `create_main_task` / `create_sub_task` identities SHALL be absent.
- `start_task`: read plan/TODO and remain execution-engine agnostic.
- `compress_task`: compact one completed workspace without deleting TODO evidence.

#### Requirement: Deprecated prompts are non-current

`prompts/commands/deprecated/` SHALL serve only as historical/reference evidence unless an explicit caller intentionally selects it or a reviewed migration re-enables it. Historical TaskAdmin/PRD patterns SHALL NOT be silently modernized or counted as active coverage. When only deprecated evidence exists, report `legacy`, not current execution coverage.

#### Requirement: Prompt edits use one normative owner

Semantic creation/maintenance SHALL load and follow `prompt-engineering`, inspect complete prompts/callers, preserve validated safety/API/permission contracts, and merge duplicate rules rather than append patches. Keep one normative owner: higher authority wins conflicts; repair the owner rather than copy system rules across files. System/skill rules needed before prompt selection SHALL NOT be demoted to optional command prompts.

#### Requirement: Project-specific values are inputs

Reusable prompts MAY require project paths, ids, URLs or choices, but SHALL validate them as explicit inputs/dynamic context rather than hardcode local-only values/secrets. For missing required input, follow higher runtime rules: ask at most one necessary question or execute a safe independent subset.

### Validation

- Static review SHALL check goal/inputs/output/failure/validation, authority layering, portable paths and active registration. Recorded static prompt-contract review: `passed`; user specification review: `passed`.
- Registration changes SHOULD run generated prompt-library/config inspection.
- Material behavior changes SHOULD use a representative disposable invocation when feasible. Recorded representative runtime invocation: `not-run`.

### Source trace

Frontmatter `sources` lists, in order, the prompt root, runtime discovery and editing contract. Parent: [Prompt index](./index.md).
