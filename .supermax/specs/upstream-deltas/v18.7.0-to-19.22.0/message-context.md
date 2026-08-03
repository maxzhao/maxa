---
title: Message and context upstream delta
authority: draft
status: comparative-draft
baseline: 558518f8d78a44198cd428f6bf8bf48bfa38d76d
latest_upstream: 2b959b2bf5fdb13e3b333c078ba549996e477b7c
---

## Source diff

Context/parser/editor-context files change; latest-upstream adds `context_management` compaction/editing/init, adds ACP session options slash command, adds MCP documentation, and changes slash-command, rules, editor-context, and variable documentation.

## Observable behavior delta

Long chats may compact or edit context through explicit context-management flows. Editor context, slash commands, rules, variables, and ACP session options may expose new inputs or produce different provider payloads. Added docs are not treated as proof without source confirmation.

## Compatibility impact

High for prompt construction, context budgets, slash-command handlers, rules/variable extensions, and consumers of message history. Compaction can change what the model receives and is therefore behaviorally significant.

## Validation and unknowns

Reviewed context-related source/doc diff. Not run: compaction thresholds, edit/retry behavior, ordering, variable/slash-command matrix, provider payload snapshots, and failure recovery. Unknown: trigger policy, token accounting, and compatibility aliases.
