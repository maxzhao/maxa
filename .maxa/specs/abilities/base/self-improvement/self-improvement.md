---
title: Self-Improvement Capture Workflow 行为规格
created: 2026-06-29
updated: 2026-09-22
type: source
doc_role: spec
authority: draft
status: experimental
capability: self-improvement-capture-workflow
sources:
  - abilities/self-improvement/SKILL.md
  - abilities/self-improvement/references/knowledge-flow.md
  - abilities/self-improvement/hooks/TaskStarted.md
  - abilities/self-improvement/hooks/TaskCompleted.md
  - .maxa/inbox/index.md
  - user-review:2026-09-15
confidence: medium
---

## Requirements

- **Capture destinations**: High-value reusable task lessons go to `.maxa/inbox/`: stable error/fix lessons → `.maxa/inbox/errors/`; non-obvious workflow learnings/corrections → `.maxa/inbox/learnings/`; tooling/structure ideas → `.maxa/inbox/feature-requests/`. Retired `.maxa/learnings/ERRORS.md`, `LEARNINGS.md`, `FEATURE_REQUESTS.md` SHALL NOT be active write targets. Knowledge stays project-local under [[specs/abilities/base/project-admin/project-vault|Project Vault Governance]]; no global promotion destination.
- **Note publication**: Before creation, minimally check nearest inbox/promoted knowledge indexes for duplicates/relevance; update/merge when appropriate. Captures SHALL include minimal metadata, TLDR and source trace, be reachable from `.maxa/inbox/index.md` or equivalent review entrypoint, and exclude secrets/PII/one-time logs.
- **Execution boundary**: TaskStarted/TaskCompleted hooks are optional and narrow. Hook-triggered capture loads `subagent` for bounded fork-agent side work under the current skill contract. Capture SHALL NOT change the main goal; broad curation/graph/feedback/layout work routes to Obsidian/ProjectAdmin.

## Validation And Review State

- Human specification review: passed by explicit user declaration on 2026-09-15.
- Not run: current TaskStarted/TaskCompleted hook smoke and representative capture dry-run. Status remains experimental.
