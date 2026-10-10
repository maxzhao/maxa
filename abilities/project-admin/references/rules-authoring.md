# `.maxa/AGENTS.md` Authoring Reference

## Purpose

`.maxa/AGENTS.md` is the project-level L0 instruction file for Maxa Agents. It gives future Agents stable project facts, execution boundaries, command entrypoints, validation expectations, and knowledge-entry links needed to work safely in the repository.

Write it as a shared Agent contract for fresh-context Agents, not human onboarding or long-form documentation.

`.maxa/AGENTS.md` must be written in English. Use English headings, bullets, placeholders, and rule text for a consistent portable contract.

## Authority Boundary

Every `.maxa/AGENTS.md` must state that it is lower priority than the main system prompt, Ability Gate, tool-safety rules, and loaded Ability instructions.

Rules:

- Do not claim highest priority.
- Do not override Ability Gate, TaskAdmin, tool schemas, safety rules, or loaded Ability instructions.
- Do not encode temporary local preferences as shared project rules.
- Do not include secrets, credentials, private tokens, or one-off logs.
- Clearly label local-only or environment-specific rules and isolate them from portable rules.

## File Role

Use `AGENTS.md` for stable, frequent, low-context project instructions.

Include:

- Project identity, scope, and ownership boundary.
- Project root placeholder and path conventions.
- Stable repository routing: where Agents should inspect first, which files are source of truth, and which paths are generated/runtime/non-source.
- Primary command and validation entrypoints.
- Project-specific safety or compatibility constraints.
- `.maxa/tasks/`, `.maxa/drafts/`, and `.maxa/` governance boundaries.
- L0 entrypoints leading to root `index.md`, generated `weave/index.md`, content/spec indexes and review inboxes; content ownership and weave maintenance route through ProjectAdmin.

Exclude:

- Task progress, active debugging state, handoff notes.
- Full research reports, design specs, long rule bodies, or note catalogs.
- Complete command logs or validation transcripts.
- Generated output, temporary drafts, scratch plans.
- Lists of every knowledge note in the project.

## Minimum Template For A New Or Empty Project

Use explicit placeholders instead of guessing unknown facts.

```markdown
# {PROJECT_NAME}

> Maxa project-level supplement. Priority is lower than the main system prompt, Ability Gate, tool-safety rules, and loaded Ability instructions.

## Project Scope

- Purpose: {one sentence, or "to be confirmed"}
- Ownership boundary: {what belongs to this repository, or "to be confirmed"}

## Project Root

`<project_dir>`

## Repository Map And Agent Routing

{routing table or bullets that tell Agents where to inspect first, which files are source of truth, and which generated/runtime paths are not source. Use `to be inspected` for unknowns; do not substitute a raw directory tree unless the project is still empty.}

## Environment And Stack

{known runtime, language, framework, package manager, OS constraints, or "to be inspected"}

## Commands And Validation

- Before shell commands, follow the session Justfile check rules.
- Build / test / lint / typecheck entrypoints: {known commands, or "to be inspected"}
- After behavior-affecting changes, run the closest relevant existing validation.

## Execution Boundaries

- `.maxa/tasks/`: TaskAdmin internal storage. Load `task-admin` before task operations.
- `.maxa/drafts/`: temporary Agent drafts, not durable knowledge or task progress.
- `.maxa/`: project knowledge Vault; use the entry chain below.

## Project Knowledge Vault

{standard project-admin knowledge Vault paragraph or concise equivalent}

## Project Knowledge And Source Entrypoints

- L0: `.maxa/AGENTS.md`
- L1: `.maxa/index.md`
- L1/L2: `.maxa/index.md`; review entry: `.maxa/inbox/index.md`
```

The generated template may contain more detail, but this minimum contract must remain.

## Mature Project Content

Add concise sections only when they help future Agents act correctly.

| Section | Include | Avoid |
| --- | --- | --- |
| Project Scope | responsibility, out-of-scope, public/downstream compatibility | broad narrative |
| Repository Map And Agent Routing | first-inspection paths, source-of-truth files, package/app responsibilities, generated/runtime/non-source markings | raw directory trees, exhaustive file listings, guesses from folder names |
| Commands And Validation | declared command entrypoints, closest checks, validation blockers/fallback discovery | assumptions that commands will fail |
| Execution Boundaries | Ability-required areas, internal storage, drafts, knowledge, generated output, local-only, shared interfaces | duplicated system-prompt rules unless project-specific |
| Knowledge Entrypoints | retrieval strategy and indexes | long-lived detail bodies or note catalogs |

## Evidence-First AGENTS Updates

Before creating or changing `AGENTS.md`, inspect enough current project state to support each stable claim. Useful sources include workspace manifests, package exports/scripts, framework route/config files, deployment/runtime config, database/migration config, command guides, and `.maxa/` indexes. Do not infer responsibilities from directory names when source files can confirm them.

Rules:

- Prefer an Agent routing map over a directory inventory. A useful map tells future Agents where to start, what each area owns, which file is authoritative, and what not to treat as source.
- Distinguish current facts from intended policy. If a project rule says one origin, command, or boundary but actual config still says another, write a check/reconcile rule instead of declaring either side as unconditional fact.
- Record only stable, reusable facts in `AGENTS.md`; move detailed rationale, investigations, and one-off mismatch notes to category indexes, reports, specs, or task progress as appropriate.
- If exploration is incomplete, use `to be inspected` / `to be confirmed` rather than filling gaps with guesses.

## Writing Style

- Prefer short, imperative, verifiable rules.
- Use stable headings and bullets over narrative prose.
- Include exact stable paths, commands, config keys, and source-of-truth files.
- Use English placeholders such as `to be inspected` or `to be confirmed`.
- Separate portable project rules from local-only notes.
- Keep examples minimal and only for format or boundary clarification.
- Avoid duplicating knowledge Vault content; point to indexes.

## Update Rules

Update `AGENTS.md` when stable project behavior changes:

- Project scope or ownership boundaries.
- Directory responsibilities.
- Command or validation entrypoints.
- Knowledge Vault entrypoints or source-layer structure.
- TaskAdmin workspace, draft, or governance boundaries.
- Repeated project-level Agent mistakes with a stable fix.

Do not update for:

- One task's progress.
- Temporary debugging facts.
- One validation run's raw output.
- Personal preferences that are not project rules.
- Knowledge that belongs in a source note, decision note, report, or task progress file.

## Maintenance Workflow

1. Read existing `AGENTS.md` if present.
2. Inspect current project source-of-truth files before writing facts: workspace manifests, command entrypoints, app/package configs, framework routing, runtime/deploy config, database/migration config, and existing `.maxa/` indexes as relevant.
3. Identify mismatches between intended policy and actual config; either reconcile them in the project or write an explicit check/reconcile rule instead of presenting stale target state as fact.
4. Preserve user-written sections unless they conflict with higher-priority rules or the requested change.
5. Patch only the target semantic section.
6. Prefer `Repository Map And Agent Routing` over `Project Structure` directory-tree inventories for mature projects.
7. Move bulky or low-frequency content into `.maxa/` and keep entry links.
8. Ensure discoverability: `AGENTS.md -> index.md -> weave/index.md / specs/index.md / content indexes`, plus the inbox review entry. Keep weave detail/budgets in its owning Ability reference, not duplicated L0 procedures.
9. Re-check authority wording against main system prompt, Ability Gate, tool-safety rules, and loaded Abilities.
10. Validate by full-file reread, Markdown/static diff review, evidence check against inspected source files, and relevant project-admin workflow checks for init/sync.

## Size And Placement

Keep `AGENTS.md` small enough for default context. Split when sections grow:

- Stable summary stays in `AGENTS.md`.
- Rationale, research, specs, decisions, and examples move to `.maxa/`.
- Active task state moves to the owning TaskAdmin TODO or linked task document.
- Drafts stay in `.maxa/drafts/` until promoted.

A good `AGENTS.md` lets a fresh Maxa Agent know what to read next, which source-of-truth files to trust, what not to touch casually, and how to validate changes without a full repository tour.
