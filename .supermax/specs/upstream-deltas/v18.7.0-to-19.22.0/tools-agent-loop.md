---
title: Tools and agent loop upstream delta
authority: draft
status: comparative-draft
baseline: 558518f8d78a44198cd428f6bf8bf48bfa38d76d
latest_upstream: 2b959b2bf5fdb13e3b333c078ba549996e477b7c
---

## Source diff

Tool documentation is renamed/expanded for agent tools; tool registry changes by 185 lines; approvals and `ask_questions` are added; command runner is replaced/reworked as `cmd_tool`; file and web tools change; background `tools_judge` is added.

## Observable behavior delta

Tool discovery/registration, approval prompts, question interaction, command execution, file deletion/creation, web fetching, tool judging, and agent-loop continuation/error handling may differ. The new names and approval flow are user-visible boundaries.

## Compatibility impact

High for custom tools and consumers of tool schemas/results. Command execution and approval changes can affect safety, blocking, retries, and continuation. Renamed documentation/tool entrypoints require migration review.

## Validation and unknowns

Reviewed registry/tool/approval source and documentation diff. Not run: tool schema snapshots, approval allow/deny, command/file failure, multi-tool ordering, judge decisions, and loop termination tests. Unknown: old command-runner alias, exact result envelopes, approval defaults, and retry limits.
