---
title: Chat lifecycle upstream delta
authority: draft
status: comparative-draft
baseline: 558518f8d78a44198cd428f6bf8bf48bfa38d76d
latest_upstream: 2b959b2bf5fdb13e3b333c078ba549996e477b7c
---

## Source diff

`interactions/chat/init.lua` and UI builder/init have large rewrites; folds/icons and buffer-diff handling change, while formatter files are removed/reworked. Chat tests and UI state tests change substantially.

## Observable behavior delta

Chat construction, message submission, UI state/rendering, folds, icons, reasoning/tool formatting, and buffer-diff presentation may differ. The scale of the rewrite makes lifecycle ordering and state transitions potentially observable even where public names remain.

## Compatibility impact

High for UI customizations, formatters, event consumers, persisted chat buffers, and code relying on internal chat state. Basic prompt submission is not assumed equivalent without runtime comparison.

## Validation and unknowns

Reviewed module-scoped diff/stat and changed test paths. Not run: full chat lifecycle tests, reload/resume, empty/error/cancel paths, fold/render snapshots, and formatter compatibility. Unknown: exact state-machine changes and persistence migration.
