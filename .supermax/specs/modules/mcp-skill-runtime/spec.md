---
title: SuperMax Built-in MCP and Skill Runtime
created: 2026-08-02
updated: 2026-08-02
doc_role: target-module-spec
authority: draft
status: partial
baseline: ../modules/tools-agent-loop/spec.md
---

# Contract

MCP and Skill tools are first-class runtime subsystems, not external CodeCompanion extensions. The runtime discovers built-in/native and project-configured MCP servers, registers their tools/resources/prompts as applicable, and manages their lifecycle under project/session ownership. Current native exports are `misc`, `subagent`, `cc_history`, `mcpx`, `genai` and `json_artifact` (`lua/util/mcphub/init.lua:1-8`). Current external server evidence includes `tauri-wdio`, with project-root environment injection and a 600000ms request timeout (`lua/plugins/ai.lua:1808-1845`). Current `ai.lua` also sets automatic server toggling and automatic tool execution and injects native server definitions before MCPHub setup (`:1800-1845`). These are target behaviors, but current MCPHub option names are not target APIs.

Skills are discovered from the shared and project-supported Skill roots, loaded through explicit metadata, and may register startup/session hooks, tools, prompt fragments and Chat input capabilities. Skill loading and restoration are lifecycle events with failure isolation. Current evidence: startup hooks are installed by `setup_startup_hooks`, loaded skills register hooks with `register_skill_hooks`, and restored messages recover hooks with `restore_hooks_from_messages` (`lua/util/skill_hooks/init.lua:117-184`); hook registry supports per-session registration, parent-chain inheritance and cascade guards (`registry.lua:48-234`); `fire_sync` and `fire` provide synchronous/asynchronous dispatch (`fire.lua:40-62`).

MCP tools and Skill tools use the common Tool Runtime contract. The default policy is automatic execution with no user authorization gate. Server/tool startup, shutdown, timeout, cancellation and schema failures remain observable and affect continuation according to the request policy.

The current `lua/util/mcphub/` and `lua/util/skill_hooks/` implementations are source evidence. The target API must not require `mcphub.nvim`, CodeCompanion extension callbacks or CodeCompanion tool classes. Project MCP configuration is `.maxa/mcp/servers.yaml` as defined by `supermax-configuration`; it defines server command/args/env/cwd, startup/request timeout, enabled state and project-root substitution. Bundled built-in native servers are registered separately and cannot be overridden by an external project server of the same reserved ID. The development mother repository's `.supermax/` is not a runtime configuration root.

## MCP lifecycle requirements from current evidence

- Native registration validates definitions, returns an existing server on duplicate registration while recording an error, and exposes tools/resources/resource templates/prompts (`mcphub/native/init.lua:12-187`).
- Native setup is one-shot and registers built-in plus configured native servers (`mcphub/native/init.lua:189-207`). The replacement runtime MUST define an explicit reload/reset path for configuration changes rather than rely on process-global one-shot state.
- Config reload failure transitions the hub to stopped/error; successful reload refreshes native server enabled state (`mcphub/hub.lua:1048-1079`).
- A disabled native server stops and an enabled disconnected server starts; changes emit one aggregate server-state update (`hub.lua:1061-1099`).
- Hub restart is guarded against concurrent restart and reports restart failure through runtime error state (`hub.lua:1303-1364`).

Dedicated replacement fixtures for external process spawn/exit, native registration collision, enable/disable, config reload, concurrent restart, request timeout, Neovim shutdown and SkillHook scope/restore are normative in `../../runtime-fixture-contract.md`. Current `misc` contains only `echo` and lifecycle notifications; the target removes the server or exposes an explicitly named diagnostic primitive rather than retaining a miscellaneous capability bucket.

## Server registry and lifecycle

Each server has immutable ID, kind (`native|external`), project/config snapshot, state, generation, capabilities revision and owned requests/process handles. Reserved mother-repository native IDs cannot be shadowed by project declarations. External server state follows the lifecycle in `runtime-fixture-contract`; every start/stop/restart/reload is idempotent by operation key.

Capabilities are published only after successful initialization and schema validation. Capability updates create a new registry revision; in-flight tool calls retain the definition revision they started with. Stop/reload prevents new calls, drains or cancels current calls by policy, then removes capabilities. Process stderr/logs are bounded/redacted and remain diagnostics, not model context unless explicitly requested through a tool.

Configuration reload computes added/removed/changed/unchanged servers. Unchanged connected servers retain generation. Changed servers restart; removed servers stop; added enabled servers start according to auto-start policy. Aggregate registry update emits once after individual transitions reach their current stable result.

## MCP requests

Tool/resource/prompt requests carry server generation and owner session/request/task identity. Timeout/cancel affects that request and may affect server state only through explicit health policy. A late response from an old generation is rejected. Transport or process failure fails pending calls with typed results so ToolBatch completion cannot hang.

## Skill discovery and load

Discovery roots are bundled/runtime global `skills/` and target-project `.maxa/skills/`; project same-name Skills shadow global Skills. The development mother repository's `.supermax/` is not a runtime Skill root. Names are stable relative IDs with at most the supported subskill depth. Metadata defines description/triggers, dependencies, MCP dependencies, visibility/resources and optional hooks/system fragments.

Load order is dependency topological order followed by requested Skill. Cycles and missing dependencies fail before partial requested-Skill activation. Successful loads are deduplicated per session while preserving provenance. Loading a Skill exposes sanitized instruction context/resources according to visibility; it never executes arbitrary project code merely because a directory exists. Python Skill scripts follow their own declared uv project runtime.

## SkillHook contract

Hook identity is `(skill_id,event_name,definition_hash,scope,owner_session|global)`. Supported load phases are `startup` and `on_load`; scopes are `global`, `session`, and declared `cascade`. Project-over-global Skill resolution also determines hook definition. Conflicting Markdown/Lua definitions for one event are validation errors.

`pre` hooks required for request composition run synchronously in deterministic priority/Skill-ID order and persist injected messages with provenance. `post`/observer hooks may run asynchronously but cannot mutate a sent request. Filters are pure payload predicates. Listener failures are isolated and typed. Once state/tombstones are durable and restored before new events. Cascade inheritance follows explicit parent-session lineage only.

Custom SkillHook event names are registered from loaded definitions; firing an unknown event or incomplete payload fails validation. Built-in event payload schemas remain owned by `events-status`.
