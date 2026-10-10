# Sync Project Governance

Purpose: repair existing `.maxa/` structure, entrypoints, and governance constraints without rewriting user-owned non-target regions. Apply `SKILL.md` boundaries and execution discipline.

## Required Workflow

Apply `references/knowledge-vault.md` checkout ownership before external work. Linked Worktrees retain all safe local governance steps and report external registration/CLI/scan checks as not applicable by policy. Do not execute prohibited setup commands and then attempt to repair their rejection. Unresolved ownership blocks required external checks; file-only completion is not full external validation.

Use `read` for `#project-admin[/references/init-layout.md]`, `#project-admin[/references/rules-authoring.md]`, and `#project-admin[/references/knowledge-vault.md]`. These checks define sync scope: do not skip required content checks or replace paragraph-level audit with file existence, keyword search, or script status unless a check only asks for existence. Reuse current evidence where it satisfies the check.

1. Complete [Git preflight](../SKILL.md#git-preflight) before project writes; reuse a current result and user decision when routed from init.
2. Check required `.maxa/` files/directories; old generated content requires explicit `wiki-to-weave.md` migration before dependent skeleton changes. Do not silently rename or create parallel areas. Fill compatible missing files; optional content roots exist only when needed/already present.
3. Check `.maxa/.gitignore`; preserve user entries and add missing entries from `assets/gitignore`.
4. Apply `references/rules-authoring.md` to fix `AGENTS.md`: L0 role, root Vault entry, evidence-backed repository routing, command/validation entrypoints, update rules, required/optional root categories, `.maxa/tasks/` ownership, and priority below main system/Ability Gate/loaded Abilities. For mature projects, replace raw directory-tree sections with first-inspection paths, source-of-truth files, and generated/runtime/non-source boundaries.
5. Check root Vault skeleton, metadata, ignore policy, default sync constraints, and required directories. Require syncable `.stignore-shared` and local `.stignore` containing exactly `#include .stignore-shared`; when needed, use the cataloged governance commands through titled `run(scope="tool")` with `--project-root` and a resolved literal path in array `args`, following the examples from `load(target="project-admin")`.
6. Check `.maxa/drafts/` exists and `.maxa/.gitignore` contains `drafts/`; drafts do not substitute for knowledge, task, or runtime source artifacts.
7. Check `AGENTS.md -> index.md -> weave/index.md`, inbox and existing content indexes. Do not regenerate weave bodies during sync; route user-requested weaving to `weave.md`.
8. If a project `justfile` exists, apply `references/justfile-guide.md` to check for missing or stale `justfile.md`.
9. Report changes; preserve user-authored non-target regions.

## Validation And Failure

Apply the scoped validation checklist in `SKILL.md`. Map requirements to `completed / not applicable / blocked / not completed` with evidence. A relevant current check need not be rerun solely to satisfy another heading.

For truncated or failed reads, try section/range reads. If required evidence remains unavailable, mark that check blocked. If any required work was not executed, report `sync partially completed` or `sync not completed`, never `sync completed`.
