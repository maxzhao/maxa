---
title: maxa Runtime Replacement Fixture Contract
created: 2026-08-02
updated: 2026-08-02
doc_role: validation-contract
authority: draft
status: partial
sources:
  - validation-matrix.md
  - current-runtime-source-inventory.md
  - hook-replacement-map.md
  - modules/chat-runtime-state/spec.md
  - modules/request-orchestrator/spec.md
  - modules/tool-runtime/spec.md
  - modules/mcp-skill-runtime/spec.md
  - modules/session-history/spec.md
  - modules/events-status/spec.md
  - modules/async-lifecycle/spec.md
confidence: high
---

# Purpose

Turn target runtime requirements into executable replacement-test boundaries. These fixtures SHALL import only replacement runtime modules and test doubles; importing `codecompanion.*`, `mcphub.*`, or current hook modules fails the acceptance gate.

## Common runtime harness

The test harness SHALL provide deterministic:

- session, request, turn, tool-batch, tool-call, task and view identities;
- monotonic clock/timer scheduler;
- provider stream source with controllable late events;
- tool executor with sync/async/cancel/error modes;
- event recorder and listener-failure injection;
- in-memory plus failure-injectable persistence;
- Neovim view/buffer adapter with detach/delete/reopen simulation;
- MCP external-process and native-server doubles;
- Skill/SkillHook filesystem and event fixtures.

Every test asserts final state, persisted state, emitted event order, owned-resource cleanup and absence of duplicate terminal effects.

## State and request orchestration

| Fixture | Stimulus | Required assertions |
| --- | --- | --- |
| `state/manual-submit-success` | visible user submit, text response | one user turn; one request; response-start once; assistant turn persisted; completed then ready |
| `state/duplicate-submit` | second manual submit while request active | second submit rejected/queued by explicit policy; no second request identity |
| `state/tool-continuation` | response contains tool calls | assistant call persisted; one ToolBatch; all results persisted; exactly one continuation request |
| `state/tool-only-response` | provider completes with calls and no text | no false empty-response failure; ToolBatch begins |
| `state/soft-stop-stream` | soft stop during provider stream | stream drains; result persists; automatic continuation suppressed; no provider cancellation |
| `state/soft-stop-tools` | soft stop during tool batch | current batch drains according to policy; callback/reset executes; no continuation request |
| `state/context-limit-busy` | usage reaches target while busy | one-shot soft-stop boundary armed and consumed |
| `state/context-limit-idle` | usage reaches target before automatic submit | auto-submit blocked and user-ready boundary produced |
| `state/watchdog-retry` | stalled request, recoverable watchdog | configured bounded retries; each gets new request generation; manual submit resets budget |
| `state/watchdog-exhausted` | all retries fail | one typed terminal failure; Chat unlocked; timer removed |
| `state/terminal-race` | success/error/cancel callbacks race | first valid terminal transition wins; later callbacks recorded/ignored without mutation |
| `state/restore-agent-loop` | restore after tool calls/results | pairing and loop state reconstructed; no duplicate continuation or manual-user trace |

## Cancellation and async ownership

| Fixture | Required assertions |
| --- | --- |
| `async/hard-cancel-provider` | provider cancel invoked once; late chunks rejected by request identity; cancelled terminal once |
| `async/hard-cancel-tool` | current/pending owned tools receive cancellation; no later queued execution; results/terminal policy explicit |
| `async/view-delete` | view resources/extmarks/timers close; session/request may continue; no invalid-buffer mutation |
| `async/chat-close` | session-owned requests/tasks/timers close; persistence/close terminal order deterministic |
| `async/nvim-exit` | best-effort cancellation; all closeable handles closed; failures reported without new work |
| `async/history-operation-close` | late save/title callback cannot resurrect or overwrite a superseded session generation |
| `async/double-cleanup` | repeated cancel/close/teardown is idempotent |

## Tool runtime

| Fixture | Required assertions |
| --- | --- |
| `tool/invalid-json` | standard invalid-call result; no handler execution; batch continuation policy applied |
| `tool/missing-required-field` | schema error contains exact field path; result paired to call identity |
| `tool/automatic-sync-success` | no approval event/UI; running/succeeded events; persisted result precedes continuation |
| `tool/automatic-failure` | no approval fallback; typed failure result; remaining-call policy deterministic |
| `tool/async-success` | task identity/owner exposed; completion accepted once |
| `tool/async-cancel-late-result` | late success cannot overwrite cancellation |
| `tool/parallel-barrier` | configured concurrency respected; stable result order policy; ToolBatchFinished once |
| `tool/display-projection` | display summary/Markdown never mutates persisted/API result messages |
| `tool/ttl-result` | discard/defer/keep/persist lifecycle changes only retention metadata/content ownership |

## MCP lifecycle

External process state machine:

```text
disabled -> stopped -> starting -> connected -> stopping -> stopped
                         |             |
                         v             v
                       failed <---- reconnecting
```

Required fixtures:

| Fixture | Required assertions |
| --- | --- |
| `mcp/config-valid-external` | command/args/env/timeout/project-root substitutions normalized without executing |
| `mcp/config-invalid` | missing command/schema/version classified before spawn |
| `mcp/external-start-ready` | process spawn and initialize handshake; tools/resources/prompts published only after connected |
| `mcp/external-start-fail` | failed state includes typed cause; no partial capability exposure; handles reaped |
| `mcp/request-timeout` | request fails independently; server policy decides retained connection/restart |
| `mcp/stop` | pending requests cancelled/failed; process terminated; state event once |
| `mcp/restart-concurrent` | one restart owner; concurrent request reports already-restarting/joins according to policy |
| `mcp/config-reload` | unchanged servers preserved; changed servers restarted; removed servers stopped; aggregate update once |
| `mcp/native-register` | schema validation and capability exposure |
| `mcp/native-duplicate` | deterministic existing/error result; no duplicate capability entries |
| `mcp/native-enable-disable` | start/stop state and aggregate event exactly once |
| `mcp/nvim-exit` | external processes and native lifecycle hooks close without UI dependency |

The target SHALL replace `misc` with an explicit diagnostic primitive or remove it. Current `misc` exposes only `echo` plus lifecycle notifications; it is not a stable core capability.

## Skill and SkillHook

| Fixture | Required assertions |
| --- | --- |
| `skill/project-overrides-global` | same-name project Skill selected; global remains discoverable only when not shadowed |
| `skill/dependency-order` | dependencies load before requested Skill; failure blocks dependent load |
| `skill/startup-global` | registered once per runtime startup |
| `skill/on-load-session` | bound only to loading session |
| `skill/cascade-child` | declared cascade hook inherited by child session, not unrelated sessions |
| `skill/pre-submit` | synchronous injection completes before prompt composition and is persisted with provenance |
| `skill/post-observer` | cannot mutate already-sent request; listener failure isolated |
| `skill/once-restore` | once/tombstone state restored from history; no second injection |
| `skill/filter` | exact payload filter and no-match behavior |
| `skill/lua-hook-failure` | typed isolated failure and no request corruption |

## Session persistence and history

### Target persisted schema

Target storage SHALL be versioned and project-scoped. Minimum session envelope:

```yaml
schema_version: integer
session_id: string
save_id: string
project_id: string
parent_session_id: string|null
created_at: integer
updated_at: integer
title: string|null
provider_id: string
protocol: string
model: string
messages: []
context_items: []
runtime_state: {}
trace:
  id: string|null
  membership: {}
status_snapshot: {}
```

`refs` is accepted only by a migration reader and normalized to `context_items`; it is never written by the target. Buffer/window/cursor data is view state, not authoritative session identity.

Required fixtures:

| Fixture | Required assertions |
| --- | --- |
| `history/create-save-open` | stable identity, atomic write/index update, same normalized messages after restore |
| `history/write-failure` | old durable state preserved; failure visible; no false saved status |
| `history/index-rebuild` | missing/corrupt index rebuilt from valid sessions; corrupt sessions isolated |
| `history/legacy-refs-migration` | `refs` normalized once to `context_items`; target version written only after successful migration |
| `history/fork` | parent lineage and copied trace membership; child mutation independent |
| `history/scratch` | unsavable until explicit save; no index entry before save |
| `history/merge-transfer` | exact selected range/order/provenance; source close behavior explicit |
| `history/rewind-redo` | manual-user boundary restored; redo submits once |
| `history/compact` | protected prefix retained; archive/trace links preserved; replacement range exact |
| `history/trace-dedup` | manual/assistant/error natural turns once; auto-submit/regenerate not manual turns |
| `history/title-late-callback` | generation result applies only to matching session/version |

## Events, spine, spinner and lualine

Spine snapshot SHALL contain:

```yaml
active_session_id: string|null
display_session_id: string|null
running_sessions: integer
active_requests: integer
warmup_tasks: integer
provider_id: string|null
model: string|null
usage: {}
context_limit: integer|null
retry: {}
notification: {}
terminal: {}
```

Required fixtures:

- State events update the snapshot synchronously before projections refresh.
- Active session and display session are independent; deleting a view does not delete session state.
- Running/request/warmup counts never go negative and return to zero after teardown.
- Spinner debounce, request start, first response, tool-argument receive, tool execution, retry and terminal phases have deterministic precedence.
- Spinner timer/extmark destruction is safe for invalid/deleted views.
- Lualine reads only spine snapshot and normalized usage/billing projections; no CodeCompanion lookup or metadata write is allowed.
- Provider quota/billing failures yield absent/stale typed projection, not runtime failure.
- Notification state and terminal error state refresh lualine through the event bus without polling plugin internals.

## Configuration and prompt composition

Required fixtures:

- runtime prompt fallback when project override is absent;
- `.maxa/system.md` precedence and deterministic placeholder expansion; the development `.supermax/` is not consulted;
- global/project Skill prompt slots, dependency order and duplicate slot policy;
- unknown nonempty slot and malformed template as typed composition errors;
- target-project `.maxa/mcp/servers.yaml` path/root substitution and no cross-project or development `.supermax` fallback;
- schema version missing/unsupported/stale classifications;
- provider presets may use arbitrary gateway IDs but MUST resolve to one of the four supported protocols;
- current preset names such as `deepseek`/`open_router` are compatibility identifiers, not additional target protocols.

## Acceptance gate

This contract remains `partial` until executable replacement tests exist for every row, persisted schema version/migration behavior is selected, repository-wide import checks prove the replacement fixture suite does not load CodeCompanion/MCPHub compatibility modules, and an isolated fixture project proves all project-local runtime reads/writes stay under `.maxa/` with the development `.supermax/` absent or inaccessible.
