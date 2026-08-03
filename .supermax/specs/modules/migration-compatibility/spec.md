---
title: SuperMax CodeCompanion Migration Compatibility
created: 2026-08-02
updated: 2026-08-02
doc_role: target-module-spec
authority: draft
status: partial
sources:
  - ../../hook-replacement-map.md
  - lua/plugins/ai.lua
  - lua/util/hooks/
---

# Compatibility boundary

During replacement, CodeCompanion is an implementation compatibility layer behind the target runtime contract. New runtime code MUST depend on target state, provider, tool, event, history and view interfaces, never directly on `codecompanion.*` internals.

## Retirement order

1. Implement and validate provider/message/stream contracts for all four protocols.
2. Implement Chat state, orchestration, tool runtime, async lifecycle and event spine.
3. Move MCP, Skill, project configuration, prompts, history and status consumers to target interfaces.
4. Replace Chat view and Actions/Commands dispatch.
5. Retire each hook only after its `hook-replacement-map.md` target has passing replacement checks.
6. Remove CodeCompanion configuration, extensions, hooks and dependency only after no target runtime path imports CodeCompanion.

## Removal gates

- Target behavior scenarios cover normal, failure, cancellation, recovery, late callback and idempotency paths.
- Four protocol fixtures and tool-only stream fixtures pass.
- MCP/Skill automatic execution, session history/trace, target-project `.maxa/` prompt/configuration, spine and lualine behavior pass replacement checks; development `.supermax/` independence is proven.
- Current production Chat behaviors have migration evidence or explicit retirement decisions.
- No active hook remains without a replacement owner.

## Compatibility facade

During migration, the facade may expose only target-shaped interfaces:

- session create/open/lookup/close and immutable snapshots;
- submit/control intents;
- provider registration/selection through the four-protocol schema;
- tool registry/execution through target call/result records;
- typed event subscription;
- history/status/view Action/Command entrypoints.

Facade methods translate to CodeCompanion internally but never return mutable CodeCompanion Chat/adapter/tool objects to new code. Every facade call emits a compatibility-usage metric containing caller module and API ID; no message content or secrets are logged. Unsupported ACP/inline/workflow/approval/command-input-Chat APIs fail explicitly.

## Cutover discipline

- One authoritative owner exists per state domain. Do not dual-write session messages/history through both runtimes without a transaction/version adapter.
- Provider replacement may run shadow parsing against recorded fixtures, but never sends duplicate production requests.
- View cutover occurs after session/state/event APIs; UI cannot become the temporary source of truth.
- MCP/Skill and status consumers migrate before removing MCPHub/CodeCompanion event compatibility.
- Rollback selects the previous facade backend only while persisted schema compatibility is guaranteed; migrations are forward-safe and preserve backups.

## Import and deletion verification

The final gate runs repository-wide tracked-source searches for `codecompanion`, `mcphub` compatibility imports, current hook setup and legacy extension registration. Remaining matches must be documentation/evidence, migration readers, or explicitly external compatibility packages. Runtime startup must succeed with CodeCompanion/MCPHub plugins absent. Generated prompt dump, four-protocol tests, runtime fixture suite and closest Neovim headless integration tests all pass before dependency removal.

Adjacent consumer disposition is recorded in `../../current-runtime-source-inventory.md` and `../../module-disposition.md`.
