---
title: SuperMax Chat Runtime State Machine
created: 2026-08-02
updated: 2026-08-02
doc_role: target-module-spec
authority: draft
status: partial
baseline: ../modules/chat-lifecycle/spec.md
---

# Contract

The runtime MUST represent Chat, Request, ToolBatch and AgentLoop as explicit stateful entities. Neovim buffers are views and MUST NOT be the sole session identity.

## Required lifecycle

`created → ready → submitted → request_started → response_started → streaming → tool_batch_pending → tool_batch_executing → continuation_pending → waiting_for_user | completed | failed | stopped → closed`.

Not every request enters every state. Every transition MUST have an owner, event, timestamp, reason and idempotency rule.

## Control operations

- `submit(intent)`: distinguishes user input, restored input and automatic continuation.
- `cancel`: requests immediate cancellation of provider request and child tasks.
- `stop`: terminates current work and prevents continuation.
- `soft_stop`: drains current response/tool batch, then prevents continuation.
- `close`: detaches the view and cancels owned tasks; late callbacks are ignored.
- `recover`: rebuilds session state from persisted messages/events and repairs orphan tool calls.

`current_request`, tool batch, retry budget, context budget, AgentLoop and view attachment are runtime-owned state, not inferred from arbitrary table fields.

## Invariants

- Terminal transitions are idempotent.
- A tool call and result MUST be paired before provider submission, or an explicit synthetic recovery result MUST be recorded.
- A callback for an old request/turn MUST NOT mutate a newer turn.
- A deleted buffer MUST NOT abort the underlying session unless the session explicitly requests close.

## Entity schemas

```yaml
session:
  id: string
  project_id: string
  generation: integer
  state: created|ready|busy|waiting_for_user|completed|failed|stopped|closed
  active_request_id: string|null
  active_tool_batch_id: string|null
  loop: {}
  views: []
request:
  id: string
  session_id: string
  turn_id: string
  generation: integer
  intent: manual|automatic|regenerate|restore|retry
  state: submitted|starting|streaming|tool_pending|completed|failed|cancelled
tool_batch:
  id: string
  request_id: string
  state: pending|running|draining|completed|failed|cancelled
  calls: []
view:
  id: string
  session_id: string
  generation: integer
  bufnr: integer|null
  state: attached|hidden|detached|closed
```

Entity identities are immutable. Generation increments when an identity's asynchronous authority is superseded; callbacks carry both ID and generation. Session terminal state and request terminal state are separate: one failed request may return a recoverable session to `waiting_for_user`, while explicit session close is final.

## Legal transition ownership

| Entity | Transition | Owner / condition |
| --- | --- | --- |
| Session | `created -> ready` | initialization/configuration/persistence owner succeeds |
| Session | `ready|waiting_for_user -> busy` | orchestrator accepts one submit intent |
| Request | `submitted -> starting -> streaming` | provider runtime; response-start may skip content but occurs once |
| Request | `streaming -> tool_pending` | normalized completed response contains calls |
| ToolBatch | `pending -> running -> draining -> completed|failed|cancelled` | tool runtime and cancellation scope |
| Session | `busy -> busy` | orchestrator chooses one automatic continuation with new request |
| Session | `busy -> waiting_for_user` | no continuation, soft stop, or recoverable failure |
| Request | active -> `completed|failed|cancelled` | one terminal compare-and-set |
| Session | non-closed -> `stopped` | explicit stop makes current work terminal and suppresses continuation |
| View | attached/hidden -> detached | buffer/window deletion; session remains |
| Session | any non-closed -> closed | explicit session close; all owned work cancelled/cleaned |

Invalid transitions return a typed error and emit a diagnostic event; they never mutate state partially. Transition effects persist/emit in a declared order: validate -> mutate in-memory state -> persist required durable boundary -> emit state event -> schedule projection/continuation.

## Recovery

Recovery validates persisted schema and reconstructs the latest consistent session generation. Active provider requests are never assumed resumable. An interrupted request becomes a typed recovery terminal record. Orphan assistant tool calls receive synthetic failed/cancelled results with provenance before any new provider request. A fully persisted completed ToolBatch with no continuation record may make exactly one continuation decision using a durable idempotency key.

Executable state/race/recovery fixtures are normative in `../../runtime-fixture-contract.md`.
