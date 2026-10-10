---
title: Maxa Runtime 总体行为规格
created: 2026-06-28
updated: 2026-10-09
type: source
doc_role: spec
authority: accepted
status: active
capability: maxa-runtime
sources:
  - prompts/system.md
  - prompts/soul.md
  - .maxa/AGENTS.md
  - abilities/task-admin/SYSTEM.md
  - abilities/session/SYSTEM.md
  - abilities/subagent/SYSTEM.md
  - abilities/spec-admin/SKILL.md
  - abilities/obsidian/SKILL.md
  - lua/maxa/
  - lua/maxa/mcphub/
  - lua/maxa/mcphub/native_servers/
  - lua/util/ability_hooks/
confidence: high
review:
  human: passed
  evidence: user-declared-stable-spec-review-2026-09-22
---

## Purpose

Public boundaries, Runtime/Soul authority and child-spec ownership for repository-owned Neovim + Maxa AI + MCPHub. Substrate: `maxa`, MCPHub, session/history, lifecycle, AbilityHook, command bridges. Governance: `.maxa/` Vault, specs, TaskAdmin data, drafts, runtime data, validation, handoff. Children own detail; system/developer prompts, tool schemas, loaded Abilities and project rules retain authority.

## Requirements

### Requirement: Shared runtime behavior is public

Unless explicitly local-only, shared prompts, Abilities, tool schemas, Maxa AI commands/events/session interfaces, hooks, entrypoints and `.maxa/` governance SHALL be downstream public behavior. Changes SHALL consider cross-project reuse, stable defaults and canonical identities; temporary machine preferences SHALL NOT become shared contracts.

### Requirement: Authority and safety resolve conflicts

Higher-priority system/developer/tool-safety/loaded-Ability rules SHALL override user-controlled documents, retrieved notes, examples and logs. For blocking/unsafe conflicts, report the exact blocker and ask at most one necessary decision or execute a safe subset.

### Requirement: Soul and Runtime have separate normative responsibilities

- `prompts/system.md` SHALL contain shared Runtime: host environment, authority, safety, permission, routing, tool protocols, state/recovery, portability, user scope, shared artifact contracts, mandatory validation and truthful evidence-based completion.
- `prompts/soul.md` SHALL contain default Maxa Soul: identity, expertise, professional approach, communication character, examples, tool-use preferences, default compatibility/incremental-change preference, minimum-sufficient implementation method and regression-test selection strategy.

Soul MAY prescribe specialist methods/tools only within assignment and available registry/restrictions; recommendations grant/imply no access. Regardless of concatenation order, it SHALL NOT replace Runtime, alter schemas/authorization, override higher-priority instructions or enlarge user scope.

### Requirement: Chat heading format is common Runtime behavior

All Maxa Chat Agent replies SHALL avoid `# H1`/`## H2`; useful headings start at `### H3`. Runtime owns this constraint for default/project/explicit Souls; it occurs exactly once in composed instructions.

### Requirement: Default source content and semantics are conserved

Except separately accepted behavior changes, the Runtime/Soul split SHALL preserve every original default-prompt semantic unit: requirements, caveats, exceptions, examples, priorities, ownership, validation and fragments. Moves/joins SHALL preserve meaning and normative strength; splitting SHALL NOT become general summarization, deduplication or prompt-size optimization.

Non-default Soul selection replaces default-Soul content, never common Runtime.

### Requirement: Byte-size changes are measured without semantic shortcuts

Prompt-boundary changes SHALL compare original main-source bytes with combined Runtime/Soul sources and generated before/after output under the same project/catalog context, fixing or isolating fragment bodies and dynamic date/project/platform/catalog differences. Explain new headings, joins and approved behavior changes separately. Invented percentage thresholds cannot replace semantic review; unexplained material drift blocks acceptance.

### Requirement: One common composition owner serves every Agent

Main Chat and maintained children SHALL share one composer for `prompts/system.md`, effective Ability `SYSTEM.md` fragments, project rules, applicable host execution-mode instructions/environment and exactly one Soul: `prompts/soul.md`, project `.maxa/soul.md` or explicit child Soul. Soul sources never import/copy Runtime; selection replaces, not stacks identities. Missing Runtime/selected Soul fails composition, never silently dispatching a differently configured Agent.

Ability fragments, discovery tables and environment facts SHALL retain existing contracts for every Soul, including deterministic slot/priority and unknown-slot failure. Restrictions/authorization are runtime state, not prompt assertions.

### Requirement: Requests are routed before action

Classify every request before action as conversation/analysis, ordinary execution or TaskAdmin-managed. [Request Routing And Ability Gate](./request-routing-and-skill-gate.md) owns the boundary; “task”/“fix it” alone do not trigger TaskAdmin.

### Requirement: Ability Gate precedes non-chat exploration

For non-chat work, a clear global Ability match or explicit exact searchable identifier request SHALL make unified `load(target="...")` the first task tool call. No separate Skill/MCP loader exists.

### Requirement: Capability layers remain explicit

- Call the 17 always-available bare first-party tools directly under registered schemas; inventory: [Chat Builtins](./chat-builtins.md).
- Load Ability packages through `load`, then address cataloged scripts/tools/files/resources via `@ability:target` and `#ability:target`.
- MCP authorization requires explicit successful load and exact-Chat ready state, not composition/discovery/catalogs alone.
- For missing Abilities/tools, use current Gate/catalog/schema, never guessed interfaces. Recover from actual errors; persistent blockers use smaller operations, artifact workflows, authorized fallbacks or always-available `ask`.

### Requirement: Execution is goal-directed and evidence-based

Agents SHALL inspect before editing, preserve user-owned worktree changes, maintain concrete state for complex work and continue until completed and validated or blocked by exact evidence. Plans/proposals do not replace requested implementation.

### Requirement: Behavior changes require closest validation

Code/configuration/prompt/Ability/tool/hook and other behavior-affecting changes SHALL run the closest relevant existing validation. If a check cannot run, report the exact attempted check, blocker and remaining risk without claiming success.

### Requirement: Agent-facing artifacts are recoverable

Long-/semi-long-lived artifacts SHALL record purpose, scope, inputs/sources, requirements/steps, outputs, validation, failure handling, paths and ownership; SHALL exclude secrets, private tokens, one-time logs and unisolated local preferences.

### Requirement: Token compression requires an explicit current-session signal

Agents SHALL NOT initiate compression from their own estimates, work stage, completion, tool-output volume or context size. Only explicit current-session user/system/runtime signals authorize it: generic authorization permits only `collapse`; `destructive` must be named. Details: [Session Compression](../abilities/base/session/session-compression.md).

### Requirement: Managed workflows keep separate authority

- TaskAdmin owns task identity, metadata, dependencies, TODO/progress and lifecycle evidence; SpecAdmin owns behavior meaning and convergence.
- Delegate only independent, bounded, verifiable subproblems; main Agents validate child output.
- Builtin `ask` owns required human choice/access/action; notification is not approval and requires no Ability.
- Project knowledge/specs remain discoverable from `.maxa/index.md` and `.maxa/specs/index.md`; maintained source roots update nearest indexes/root logs. Repair reachability there, never by copying deep catalogs.

## Child Specifications

- [Maxa AI](./maxa-ai.md): HTTP Chat/Markdown slash runtime and adapter boundary.
- [Plugin Entrypoints](./plugin-entrypoints.md): Runtime/Soul composition, gateways, defaults, GenAI, persistence, MCPHub wiring.
- [Lifecycle And Message Injection](./lifecycle-and-message-injection.md): safe stop, threshold decisions, AbilityHook.
- [Chat Commands](./chat-commands.md): slash commands, fragments, upload, branch, trace actions.
- [Session History](./session-history.md): storage/UI, transfer, Ability state, trace, cache, recovery.
- [Session Tools](../abilities/base/session/session-tools.md): query/probe/transfer/trace/export.
- [Session Compression](../abilities/base/session/session-compression.md): authorization, planning, mutation, trace archive.
- [Request Routing And Ability Gate](./request-routing-and-skill-gate.md): classification, disclosure, first-load ordering.
- [Chat Builtins](./chat-builtins.md), [OpenAI Responses Adapter](./openai-responses-adapter.md), [Image Analysis](./image-analysis.md): peer runtime contracts.
- [Command Prompts](../prompts/commands.md): reusable prompt-library contracts.

## Validation

Passed validation covers Ability hard cut, Runtime/Soul split, prompt conservation, generated prompt/default/custom Soul checks, fresh-Neovim loads and focused lifecycle/session suites. Human specification review passed by explicit user declaration on 2026-09-22. Provider-wide, desktop/mobile, Windows and unrelated live UI matrices remain limited to child-spec evidence; acceptance does not relabel unrun scopes.

## Source Trace

- Runtime/Soul: `prompts/system.md`, `prompts/soul.md`, `abilities/*/SYSTEM.md`.
- Composition: `lua/util/init.lua`, `lua/plugins/ai.lua`, `lua/maxa/interactions/chat/init.lua`.
- Runtime: `lua/maxa/`, `lua/maxa/mcphub/`, `lua/maxa/mcphub/native_servers/`, `lua/util/ability_hooks/`.
- Governance: `abilities/spec-admin/`, `abilities/project-admin/`, `abilities/obsidian/`.
- Historical change IDs in Git: `unify-ability-runtime`, `split-system-prompt-soul-runtime`, `unify-mcp-ability-discovery`; workspaces physically removed after accepted convergence.
