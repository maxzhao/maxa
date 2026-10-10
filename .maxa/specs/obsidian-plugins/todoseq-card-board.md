---
title: TODOseq Card Board Plugin 行为规格
created: 2026-06-28
updated: 2026-09-15
type: source
doc_role: spec
authority: draft
status: experimental
capability: todoseq-card-board
sources:
  - obsidian-plugins/todoseq-card-board/manifest.json
  - obsidian-plugins/todoseq-card-board/package.json
  - obsidian-plugins/todoseq-card-board/src/Main.elm
  - obsidian-plugins/todoseq-card-board/src/Worker.elm
  - obsidian-plugins/todoseq-card-board/src/TaskItem.elm
  - obsidian-plugins/todoseq-card-board/src/TaskList.elm
  - obsidian-plugins/todoseq-card-board/src/InteropPorts.elm
  - obsidian-plugins/todoseq-card-board/src/Board.elm
  - obsidian-plugins/todoseq-card-board/src/BoardConfig.elm
  - user-review:2026-09-15
confidence: medium
---

## Requirements

- **Source authority**: `todoseq-card-board` presents configurable boards for general TODOseq-compatible Markdown and commits interactions back to source. Source Markdown, including unsupported lines, remains authoritative; board state SHALL NOT become an independent durable task store. The plugin neither depends on nor recreates retired TaskAdmin export-to-knowledge behavior and is not TaskAdmin authority.
- **Parsing**: `TaskList`/`TaskItem` SHALL derive supported identifiers, title, tags, dates, state, subtasks and source context from Markdown.
- **Rendering**: `Main` and board/config/column modules SHALL render cards according to filters, columns, dates, tags, properties and defaults. Missing cards may reflect filters/settings rather than missing source.
- **Worker**: `Worker.elm` owns bulk ingestion/session diffing and emits task lists, additions/deletions or Markdown write-back data through worker ports.
- **Integration**: Typed Elm/Obsidian ports SHALL mediate opening source, rendering Markdown, editing, rewriting, deleting, moving, toggling or cycling task state through Obsidian integration.

## Validation And Review State

- Historical checks: `node --check main.js` passed; `npm test` failed during Elm compilation because generated/fixture `InteropDefinitions.Flags` types had drifted. No later passing Elm suite is recorded in the audited input.
- Human specification review passed by explicit user declaration on 2026-09-15.
- Not run: repaired Elm/TypeScript tests and live Vault board/write-back validation. Status remains experimental.
