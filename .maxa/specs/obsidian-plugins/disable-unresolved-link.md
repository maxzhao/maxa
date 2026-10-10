---
title: Disable Unresolved Link Plugin 行为规格
created: 2026-06-28
updated: 2026-09-15
type: source
doc_role: spec
authority: draft
status: experimental
capability: disable-unresolved-link
sources:
  - obsidian-plugins/disable-unresolved-link/manifest.json
  - obsidian-plugins/disable-unresolved-link/package.json
  - obsidian-plugins/disable-unresolved-link/src/main.ts
  - user-review:2026-09-15
confidence: medium
---

> **TLDR**: Confirm before Obsidian creates/opens unresolved wikilink targets.

## Requirements

- **Link handling**: For unresolved notes, `openLinkText` SHALL show confirmation before invoking original create/open behavior; cancellation SHALL leave the target uncreated. Resolved targets retain normal Obsidian behavior.
- **Patch lifecycle**: The patch SHALL preserve the original function, avoid recursive wrapping and restore lifecycle state on unload as required.

## Validation And Review State

- Historical TypeScript typecheck and built JavaScript syntax checks: passed.
- Human specification review: passed by explicit user declaration on 2026-09-15.
- Current live resolved/unresolved click and unload restoration smoke: not run; status remains experimental.
