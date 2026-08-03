---
title: SuperMax Actions and Commands Runtime
created: 2026-08-02
updated: 2026-08-02
doc_role: target-module-spec
authority: draft
status: partial
baseline: ../modules/actions-extensions/spec.md
---

# Contract

Actions and Commands remain supported. The runtime MUST provide registration, discovery, declared input schema, context resolution, dispatch, result/error handling and lifecycle events.

## Current inventory

- Chat entry: normal/visual `CodeCompanionChat` is the retained conversational entry; the `CodeCompanionCmd` mapping at `lua/plugins/ai.lua:690-695` is removed from the target.
- Palette/history: `CodeCompanionActions` and `CodeCompanionHistory` remain Action/Command entrypoints (`ai.lua:720-721`) but must target the new runtime rather than CodeCompanion.
- Chat keymap Actions: provider/model selection, image provider/adapter selection, session-status panel, notification toggle, soft stop, context-limit stop, Telegram attach/status and Gemini thinking toggle (`ai.lua:700-850`).
- Chat input Commands: compaction, session/draft/spec/article pickers, trace, fork/scratch/save/merge, summarize, rewind/redo, protected-prefix clearing, fragments, agent loop/repeat and skill picker (`ai.lua:889-1050`).
- Tool default: `mcpx` is enabled and tool errors auto-submit (`ai.lua:1052-1061`).

Each inventory entry requires a target owner and explicit mutation/persistence semantics before implementation migration.

- A Command is a named executable operation with input, context, effect, output and failure contract.
- An Action is a user/runtime-facing operation that may invoke a Command, mutate Chat/session context or submit a Chat intent.
- Actions and Commands may be surfaced through Chat input, keymaps or a runtime palette, but MUST NOT require a second conversational Chat mode.
- They may operate without user authorization when they invoke MCP/Skill execution under the confirmed automatic-execution policy.
- History, compaction, provider/model selection, context insertion and project operations are candidates for built-in Commands; each must declare mutation and persistence behavior.

Extension registration is explicit and idempotent. Dispatch failures produce typed events and do not leave the Chat/request state locked.

## Registry contract

```yaml
id: namespaced-operation-id
kind: action|command
title: string
input_schema: object
contexts: [global|project|session|view|selection]
mutates: [none|view|session|project_config|history|filesystem|external]
requires_idle_request: true|false
persistence: none|session|project|external
handler: runtime-owned callable
```

Duplicate IDs with different definition hashes fail registration. Discovery is deterministic by category/order/ID and applies context predicates without executing handlers. Dispatch validates input and context snapshot, emits started/terminal events and returns a typed result. A handler may submit a declared Chat intent only through `request-orchestrator`.

## Built-in ownership and mutation

| Operation family | Owner / mutation contract |
| --- | --- |
| provider/model selection | session configuration; takes effect at next safe request boundary; project default changes only through explicit project-config Action |
| soft/context-limit stop | request-orchestrator control; no history rewrite |
| image/provider settings | session/view configuration plus validated attachment/provider capability |
| session status/stats | read-only projection over normalized session/spine snapshots |
| notification/Telegram attach/status | optional event/session integration; external binding state explicit |
| compact/collapse | session-history generation change with archive/trace provenance |
| fork/scratch/save/merge/transfer | session-history lineage/persistence transaction |
| rewind/redo | session-history generation mutation; redo submits one explicit intent |
| trace start/query | session-history trace membership/state |
| fragment/draft/spec/article picker | context insertion snapshot; source selection itself is view-only |
| AgentLoop/repeat | explicit session loop state and orchestrator intent; bounded stop policy |
| Skill picker/load | MCP/Skill runtime; loaded context and hooks persist with provenance |
| buffer translation | optional Command; provider request plus project translate-cache, no Chat identity mutation unless explicitly inserted |

Removed workflow frontmatter/group sequencing is rejected as unsupported. A list of ordinary independent Actions is not a workflow runtime. Extension handlers use target interfaces only; compatibility extensions are wrapped by `migration-compatibility` and cannot register unsupported conversational surfaces.

Required dispatch/mutation/persistence fixtures are included by the owning modules in `../../runtime-fixture-contract.md`.
