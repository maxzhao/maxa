---
title: SuperMax Events Spine and Lualine Status
created: 2026-08-02
updated: 2026-08-02
doc_role: target-module-spec
authority: draft
status: partial
baseline: ../modules/events-integration/spec.md
---

# Event contract

The runtime MUST expose ordered, session-scoped events for ChatSubmitted, RequestStarted, ResponseStarted, MessageDelta, ToolCallStarted, ToolCallFinished, ToolBatchFinished, ContinuationDecided, ChatStopped, ChatCompleted, ChatFailed and ChatClosed. Actions, Commands, MCP, Skill and history operations emit their own typed events through the same bus.

Every event includes session/chat/request/turn identity, timestamp, state, reason and optional buffer/view identity. Terminal events are idempotent. Listener errors are isolated from the main runtime unless the event is explicitly transactional.

Current scenario evidence requires: response-started fires once on first rendered assistant content; manual submit trace records only visible user input; auto-submit/regenerate do not create manual-user turns; successful completion records the final assistant turn; stop/error records a distinct empty error turn when needed and suppresses duplicate done capture; untracked sessions create no trace events. Evidence: `chat_response_started_event_test.lua` and `session_trace_lifecycle_test.lua`.

## SkillHook

SkillHook is a built-in consumer/extension mechanism over the event bus. Synchronous pre-submit injections MUST complete before request composition; asynchronous observers MUST NOT mutate an already-composed request.

## Spine and lualine

Spine is the authoritative aggregate status for active sessions and tasks. It tracks active session, display session, running count, warmup/task count, spinner phase, provider/model, token count/percentage/context limit, notification state and terminal error state. Lualine renders a projection of spine and refreshes on state events; it MUST NOT query CodeCompanion internals or use a buffer as sole identity.

Current status evidence: `lua/util/codecompanion/status/state.lua` maintains request/warmup counts, active/display buffer identity, per-chat running state and a 100ms spinner-driven lualine refresh (`:8-70`). Token extraction currently falls back through UI token state, global buffer metadata, persisted chat status and adapter totals (`:132-176`); the target replaces this with `streaming-usage` as the sole normalized source. Current lualine renders provider/model and persists token/context status metadata (`lua/util/codecompanion/status/lualine.lua:45-129`).

The target spine snapshot and fixture requirements are normative in `../../runtime-fixture-contract.md`. Active session identity is independent from display view identity. Request/running/warmup counters never go negative; event handlers update state before projection refresh. Spinner phases have deterministic precedence across request start, response start, tool-argument reception, tool execution, retry and terminal state. Timer/extmark cleanup tolerates deleted views. Lualine reads the spine snapshot only and MUST NOT resolve CodeCompanion chats or write compatibility metadata. Billing/quota is an optional provider projection whose failure never fails the Chat runtime.

## Event envelope and delivery

```yaml
event_id: string
type: string
timestamp: integer
project_id: string
session_id: string|null
request_id: string|null
turn_id: string|null
tool_batch_id: string|null
tool_call_id: string|null
task_id: string|null
view_id: string|null
generation: integer|null
sequence: integer
reason: string|null
payload: {}
```

Sequence is monotonic per session and assigned after state mutation. Durable lifecycle events are appended to trace before external asynchronous observers run. Internal reducers and synchronous pre-composition hooks run in a declared transactional phase; ordinary listeners are non-transactional and failure-isolated. Re-emitting the same `event_id` has no second reducer/trace effect.

Ordering invariants:

- `ChatSubmitted < RequestStarted < ResponseStarted? < deltas/tool-args < RequestTerminal`.
- Required message/tool/usage persistence precedes the corresponding durable terminal event.
- `ToolCallStarted < ToolCallTerminal`; all call terminals precede `ToolBatchFinished`.
- `ToolBatchFinished < ContinuationDecided < next ChatSubmitted` when continuing.
- `ChatClosed` follows cancellation/cleanup initiation and no later event may mutate the closed session generation.

Events containing large/raw content carry bounded summaries plus references; secrets and complete tool parameters are redacted according to event schema. Trace may store durable normalized content through session-history ownership, not by leaking it in every event payload.

## Status reduction

Spine is a pure reducer over target state/events plus optional quota snapshot. Reducer output is immutable and revisioned. UI/lualine refresh is coalesced and may lag the reducer, but querying the snapshot immediately after an event observes the new revision. On restore, spine initializes from session/status persistence then reconciles live owned tasks; stale `running` flags without live work are repaired and recorded.
