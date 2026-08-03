---
title: maxa Runtime Implementation Sequence
created: 2026-08-02
updated: 2026-08-02
doc_role: implementation-plan
authority: draft
status: ready-for-planning
sources:
  - module-disposition.md
  - protocol-fixture-contract.md
  - runtime-fixture-contract.md
  - current-runtime-source-inventory.md
  - hook-replacement-map.md
---

# Goal

Implement the target runtime inside this LazyVim/Neovim development mother repository, converge against replacement fixtures, then remove CodeCompanion/MCPHub compatibility. The mother repository's `.supermax/` remains Agent/knowledge/specification infrastructure only; the delivered runtime binds each target project to `.maxa/` and must operate without `.supermax/`. This checklist is implementation sequencing, not TaskAdmin status/progress.

## Proposed runtime ownership layout

Names are semantic target boundaries; final paths may adapt to repository conventions without merging ownership:

```text
lua/maxa/runtime/
├── config/          # project discovery, schema, immutable snapshots, prompt composer
├── protocol/        # openai_chat, openai_responses, anthropic_messages, gemini
├── conversation/    # normalized messages/context/content parts
├── session/         # session state, persistence, history, trace, recovery
├── orchestrator/    # submit intents, request lifecycle, continuation/retry/stop
├── tools/           # registry, validation, batches, async/TTL results
├── mcp/             # native/external server registry and process lifecycle
├── skills/          # discovery, load, dependencies, SkillHook
├── events/          # typed bus and spine reducer
├── host/nvim/       # Chat view/input, lualine/spinner, Actions/Commands
└── compat/          # temporary CodeCompanion/MCPHub facade and metrics
```

Avoid generic `utils`, `helpers`, `misc`, or a facade that hides domain ownership. Small stable primitives belong beside their owner or in an explicitly named low-level module.

## Phase 0 — Test harness and schemas

Inputs: `protocol-fixture-contract.md`, `runtime-fixture-contract.md`.

- [ ] Create deterministic clock/timer, event recorder, provider stream, tool executor, persistence, view and MCP process test doubles.
- [ ] Define normalized IDs, errors, messages/content parts, usage, events, configuration and persisted session schemas.
- [ ] Add import guards: replacement tests/modules cannot load `codecompanion.*`, `mcphub.*`, or `lua/util/hooks/*`.
- [ ] Materialize fixture directory conventions and snapshot comparison helpers.
- [ ] Add schema/fixture lint and one minimal end-to-end empty runtime test.

Gate: schemas and harness pass without compatibility plugins installed.

## Phase 1 — Configuration and normalized model

- [ ] Implement project-root binding and immutable `.maxa/runtime.yaml` snapshot; reject/fail closed rather than falling back to the development `.supermax/`.
- [ ] Implement `.maxa/mcp/servers.yaml` validation/substitution/redaction.
- [ ] Implement runtime/project system prompt composition and source manifest.
- [ ] Implement Skill table/SYSTEM slot discovery with deterministic ordering and failures.
- [ ] Implement normalized messages, content parts, context items and request composition.
- [ ] Implement schema version/error classifications and project isolation tests.

Gate: configuration/prompt/context fixtures pass; no provider/network dependency.

## Phase 2 — Protocol adapters

Implement adapters independently against data fixtures:

1. OpenAI Chat Completions.
2. OpenAI Responses.
3. Anthropic Messages.
4. Gemini native API using the verified official contract in `protocol-fixture-contract.md`.

For each adapter:

- [ ] request mapping;
- [ ] streamed/non-streamed parser;
- [ ] tool declaration/call/result mapping;
- [ ] reasoning/image capability policy;
- [ ] usage and finish/error normalization;
- [ ] cancellation and late-event rejection;
- [ ] all required protocol fixtures.

Gate: all four fixture groups pass. Do not route Gemini through Google's OpenAI-compatible endpoint.

## Phase 3 — Session state and request orchestrator

- [ ] Implement explicit Session/Request/ToolBatch/View entities and legal transition reducer.
- [ ] Implement submit-intent idempotency and manual/automatic/regenerate/restore/retry semantics.
- [ ] Implement provider request ownership, progress and one terminal compare-and-set.
- [ ] Implement continuation decision table and durable idempotency key.
- [ ] Implement hard cancel, stop, soft stop, context-stop, watchdog/backoff and compaction boundary.
- [ ] Implement stale callback/generation rejection.

Gate: all state/orchestrator/async fixtures pass with fake providers/tools.

## Phase 4 — Tool, MCP and Skill runtime

- [ ] Implement target Tool registry/schema normalization and automatic execution.
- [ ] Implement sequential/default and configured concurrent ToolBatch execution/barrier.
- [ ] Implement async task ownership/cancel/poll and TTL result lifecycle.
- [ ] Port required native MCP primitives by semantic server ownership; remove `misc` bucket.
- [ ] Implement external MCP stdio process lifecycle, config diff/reload and capability revisions.
- [ ] Implement Skill discovery/dependencies/project override and sanitized resources.
- [ ] Implement SkillHook load/scope/filter/pre/post/once/cascade/restore.

Gate: tool/MCP/SkillHook fixtures pass; no approval/permission UI exists.

## Phase 5 — Persistence, history and recovery

- [ ] Implement `.maxa/history` schema version 1 and atomic session/index writes; never persist target sessions under `.supermax/history`.
- [ ] Implement legacy no-version/`refs` migration with backup and corrupt isolation.
- [ ] Implement trace, membership, turn de-duplication and compaction archives.
- [ ] Implement fork/scratch/save/merge/transfer/rewind/redo/title/recovery.
- [ ] Implement restart recovery across absent views and unavailable MCP servers.
- [ ] Implement session stats/status projections from normalized data.

Gate: every history/recovery fixture passes, including injected write/index/title races.

## Phase 6 — Events, spine and Neovim host

- [ ] Implement typed event bus, sequence/idempotency, transactional reducers and isolated observers.
- [ ] Implement immutable spine reducer and optional billing/quota projection.
- [ ] Implement Chat view attach/hide/detach/reattach/close and snapshot rendering.
- [ ] Implement input revision capture, context/attachment selection and safe provider/model changes.
- [ ] Implement spinner and lualine projections over spine only.
- [ ] Implement Action/Command registry, palette/keymaps and built-in operation families.
- [ ] Port optional translation/Telegram notification/status-panel consumers to target APIs.
- [ ] Keep TaskBrowser as an external public-event/spine consumer.

Gate: host/view/status/Action/Command fixtures and closest headless Neovim integration tests pass.

## Phase 7 — Compatibility cutover

- [ ] Implement target-shaped compatibility facade and usage metrics.
- [ ] Route current `ai.lua` entrypoints to target interfaces without exposing CodeCompanion objects.
- [ ] Retire hooks one-by-one only when their mapped replacement fixtures pass.
- [ ] Migrate history/configuration safely; preserve rollback only while schemas remain compatible.
- [ ] Remove legacy display-history, direct CodeCompanion utility consumers and MCPHub polling/restart patches.
- [ ] Remove CodeCompanion/MCPHub setup/dependencies after repository-wide imports are clean.
- [ ] Start Neovim with compatibility plugins absent and run complete generated-prompt/protocol/runtime/headless validation.

Gate: every removal criterion in `migration-compatibility` and `hook-replacement-map.md` passes, and a fixture target project containing `.maxa/` runs with the development mother repository's `.supermax/` absent or inaccessible.

## Serial/parallel constraints

- Protocol adapters may be implemented in parallel after common schemas/harness stabilize.
- Session reducer and orchestrator are coupled and remain one serial ownership stream.
- Tool runtime precedes MCP/Skill adapters; MCP and Skill discovery may proceed independently after Tool registry stabilizes.
- Persistence schema/migrations remain serial; UI/status work may proceed in parallel against immutable snapshots.
- Hook retirement is serial by ownership group and follows passing replacement evidence.

## Blockers before implementation acceptance

- Official protocol sources were captured through Context7 on 2026-08-02; implementation must review them for drift and preserve the cited field/event contracts. Direct `web-fetch` remained unavailable but is not an evidence blocker.
- Exact Neovim test entrypoints for the new runtime will be selected when implementation files exist.
- TaskAdmin tasks may be created later if requested; this document does not create or track TaskAdmin lifecycle/status.
