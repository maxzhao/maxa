# Upgrade Project Governance

Purpose: select and apply a documented versioned project-admin upgrade. Apply `SKILL.md` ownership, portability, and scoped validation rules.

## Inputs And Workflow

Apply checkout ownership from `references/knowledge-vault.md` before external steps. Linked Worktrees perform local-only upgrade work and mark external steps not applicable. Ordinary `ensure` never retargets historical registrations; a registration-path change requires separately authorized repair, not an implicit side effect of a layout upgrade command.

1. Verify project root and upgrade intent from the user's request. “upgrade project”, “upgrade `.maxa`”, “upgrade to latest Maxa project layout”, “v0 to v1”, and “root Vault layout upgrade” are upgrade requests; do not ask the user to repeat clear intent.
2. Call `read(path="#project-admin[/references/upgrades/index.md]")` to identify available paths. Inspect current state before assuming the latest guide applies.
3. Inspect governance state, entry chain, root directories, metadata, ignore policy, and relevant reports/indexes.
4. Select the matching upgrade guide and load its cataloged `#project-admin[/references/upgrades/...]` address. If none exists, report the gap; use `migrate` or `sync` only for safe compatible repairs.
5. Execute the safe mechanical steps documented by that guide. Do not automatically migrate semantic document bodies unless it explicitly allows this.
6. For legacy or retired paths such as `.maxa/knowledge/`, use report-driven migration and preserve old content until review/retirement is explicit.
7. Validate with the selected guide, `references/knowledge-vault.md`, and relevant scripts.
8. Report upgrade path, changed files, skipped/manual items, validation, and whether follow-up `sync` is needed.

## Failure And Completion

A missing guide or unresolved migration decision is not permission to improvise a breaking upgrade. Continue only safe authorized preparation, report exact blockers, and do not claim completion while required checks or migration decisions remain unresolved.
