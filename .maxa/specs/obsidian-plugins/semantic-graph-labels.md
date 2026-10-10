---
title: Semantic Graph Labels Plugin 行为规格
created: 2026-06-28
updated: 2026-09-15
type: source
doc_role: spec
authority: draft
status: experimental
capability: semantic-graph-labels
sources:
  - obsidian-plugins/semantic-graph-labels/manifest.json
  - obsidian-plugins/semantic-graph-labels/package.json
  - obsidian-plugins/semantic-graph-labels/src/main.ts
  - user-review:2026-09-15
confidence: medium
---

## Requirements

- **Labels**: In graph/localgraph views, nodes resolving to Markdown files with a semantic frontmatter `title` SHALL display that title; otherwise use Obsidian's original display text. File paths, note identity and links (including wikilinks) remain unchanged.
- **Refresh**: Layout, metadata, rename and delete events SHALL schedule refresh when visible labels may have changed.
- **Patch lifecycle**: Prototype/method patches SHALL preserve original functions, avoid recursive re-patching and restore or clean up on unload where lifecycle requires it.

## Validation And Review State

- Historical TypeScript typecheck and built JavaScript syntax checks passed; human specification review passed by explicit user declaration on 2026-09-15.
- Current live graph/localgraph title-update and unload-restoration smoke: not run; status remains experimental.
