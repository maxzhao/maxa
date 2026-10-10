---
title: Sync Conflict Resolver Plugin 行为规格
created: 2026-06-28
updated: 2026-09-15
type: source
doc_role: spec
authority: draft
status: experimental
capability: sync-conflict-resolver
sources:
  - obsidian-plugins/sync-conflict-resolver/manifest.json
  - obsidian-plugins/sync-conflict-resolver/package.json
  - obsidian-plugins/sync-conflict-resolver/src/main.ts
  - user-review:2026-09-15
confidence: medium
---

## Requirements

- **Discovery**: `sync-conflict-resolver` SHALL target supported Syncthing `.sync-conflict-YYYYMMDD-HHMMSS-XXXXXXX` conflict copies, excluding unsupported hidden-path noise according to plugin policy.
- **Structured merge sections**: With reliable base/ours/theirs content, three-way clean sections are marked automatic and disagreements expose ours/theirs/base choices before final acceptance. Without a reliable base, the plugin MAY use its supported two-way structured merge path.
- **User decision**: Conflict content SHALL NOT be silently discarded or committed as resolved without the required user decision.

## Validation And Review State

- Passed: historical TypeScript typecheck and built JavaScript syntax checks; human specification review explicitly declared by the user on 2026-09-15.
- Not run: current live Syncthing conflict discovery, merge modal, and write-result acceptance smoke. Status remains experimental.
