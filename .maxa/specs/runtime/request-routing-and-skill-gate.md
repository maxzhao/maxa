---
title: 请求路由与 Ability Gate 行为规格
created: 2026-06-28
updated: 2026-10-09
type: source
doc_role: spec
authority: accepted
status: active
capability: request-routing-ability-gate
sources:
  - prompts/system.md
  - abilities/task-admin/SYSTEM.md
  - abilities/spec-admin/SKILL.md
  - abilities/ability-creator/SKILL.md
  - abilities/ability-creator/SYSTEM.md
  - lua/util/init.lua
  - lua/util/ability_catalog.lua
  - lua/maxa/interactions/chat/tools/builtin/tools/builtin_load.lua
  - tests/util_ability_visibility_index_spec.lua
  - tests/system_prompt_contract_spec.lua
confidence: high
review:
  human: passed
  evidence: user-declared-stable-spec-review-2026-09-22
---

## Scope

Owns request classification, TaskAdmin negative boundary, Ability Gate ordering, generated discovery disclosure and late-match repair. External owners:

- [Ability Package And Authoring](./package-and-authoring.md): package/source/load transactions; identity, overlay, dependency, executor, catalog and restore details.
- [TaskAdmin Core](../abilities/base/task-admin/core.md): TaskAdmin lifecycle.
- [MCPHub Runtime](./mcphub-runtime.md): MCP administrator/transport policy.

## Requirements

### Requirement: Classify every request before action

| Request | Route |
| --- | --- |
| Conversation/analysis without immediate edits, commands or tools | Answer directly; no TaskAdmin. |
| Ordinary inspection/edit/debug/implementation/validation | Execute without TaskAdmin lifecycle events or metadata/plan/TODO/tag reads unless the goal requires them. |
| Explicit TaskAdmin request, task id/tag/TODO/current task/next task/task workspace/`resolve_task`, numbered TaskAdmin operation, or work from `.maxa/tasks/` | Full TaskAdmin Protocol. |

Generic “任务”/“修一下”/“帮我改”/“处理一下” alone SHALL NOT trigger TaskAdmin; ambiguous wording stays ordinary until an explicit managed-work signal.

### Requirement: TaskAdmin routing is a workflow boundary

TaskAdmin work SHALL first load `task-admin`, resolve integer identity/workspace through cataloged scripts, read plan then TODO, and obey complete lifecycle events, TODO read-before-write, workspace preflight, validation and completion gates. TaskAdmin neither selects nor governs the execution engine.

### Requirement: Ability Gate precedes exploration

Before non-chat file reads/searches/edits, commands or capability targets:

| Match | Gate result |
| --- | --- |
| Clear global Ability match | Unified `load(target="<ability>")` SHALL be the first task tool call regardless of source type, e.g. `time` → `load(target="time")`. |
| Explicit exact Searchable Ability Name Index request | SHALL load that identifier directly; ordinary word matches do not qualify. |
| None | MAY proceed without an Ability. |

Separate Skill/MCP loaders never satisfy the gate. Missing/blank/invalid identifiers return the exact validation error, never a guessed alias.

### Requirement: Ability disclosure follows the effective catalog

Discovery SHALL be deterministic for the exact project, with stable ordering and Markdown-safe rows/indexes. A same-named composite emits one package-owned row.

| Source | Disclosure |
| --- | --- |
| Skill-backed/composite | `visibility=global`: full name, description, triggers; `visibility=search`: exact identifier only; `visibility=hidden`: omitted, but exact known identifiers remain directly loadable under normal catalog/policy rules. |
| Allowed MCP-only | Resolved description: full name, description, optional triggers, without requiring explicit `visibility=global`; no description: exact identifier only. |
| MCP-only `disabled=true` | Omitted and unavailable regardless of discovery metadata/prior connection. |

### Requirement: Common prompt source is independent of MCP details

Authored `prompts/system.md` SHALL retain generic Ability routing/addressing and generated table/fragment placeholders, without hand-maintained MCP-specific sections, Server rows, source-specific authorization paragraphs or a `MCPHub` introduction. An Ability `SYSTEM.md` fragment owns necessary pre-load activation/authorization/connected-only constraints, present for default and custom Souls. Generated prompts MAY contain effective Ability metadata and Ability-owned MCP rules; neither common source nor Soul duplicates a static Server table.

### Requirement: Disclosure and package visibility do not grant MCP permission

Discovery SHALL NOT load Abilities, start/reconnect backends or Servers, authorize Chats, switch process-global workspace/UI state, persist metadata or expose raw connection configuration. `disabled=false` only permits activation; actual MCP activation/authorization requires explicit `load`. Dispatch stays connected-only: no auto-load or reconnect.

### Requirement: Loaded Abilities become active exact-Chat context

Successful root `load` SHALL publish one complete committed revision for the exact invoking Chat/workspace: sanitized instructions, effective roots/metadata, protected catalog-bearing result association, applicable MCP authorization/guidance and prepared on-load hooks. Dependencies commit first; unchanged loads deduplicate context. Failed/partial preparation creates no partial root readiness: report committed dependencies and retained transport effects exactly; never claim the root loaded.

### Requirement: Late-discovered relevant Ability is loaded before further scoped work

When a relevant Ability emerges after initial exploration, the Agent SHALL load it before continuing newly scoped work and reconcile conflicting prior actions. A late match never retroactively authorizes earlier capability use.

## Validation

| Check | Contract coverage |
| --- | --- |
| `tests/util_ability_visibility_index_spec.lua` | Package global/search/hidden; described/name-only/disabled MCP-only disclosure; one-row composite. |
| `tests/system_prompt_contract_spec.lua` | Generated Ability Gate/table/index and common Runtime contract. |
| `tests/ability_catalog_test.lua` | Exact project/global source composition, metadata, side-effect-free discovery. |
| `tests/builtin_load_ability_test.lua` | Exact-Chat root/dependency/composite load transaction. |

Human specification review passed by explicit user declaration on 2026-09-22.

## Source Trace

- Policy/template: `prompts/system.md`, Ability `SYSTEM.md` fragments; discovery: `lua/util/init.lua`, `lua/util/ability_catalog.lua`; loader: `lua/maxa/interactions/chat/tools/builtin/tools/builtin_load.lua`.
- Historical change IDs in Git: `unify-ability-runtime`, `unify-mcp-ability-discovery`; their workspaces were physically removed after stable convergence.
