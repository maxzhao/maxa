---
title: SuperMax Request Orchestrator and Continuation Policy
created: 2026-08-02
updated: 2026-08-02
doc_role: target-module-spec
authority: draft
status: partial
baseline: ../modules/chat-lifecycle/spec.md
---

# Pipeline

The runtime MUST own this sequence:

`submit intent → compose context → build normalized request → provider stream → normalize response → execute tool batch → persist results → decide continuation → submit next turn or wait/terminate`.

## Continuation decision

The decision MUST consider:

- user intent and AgentLoop state;
- tool batch completion;
- soft-stop request;
- context budget and compaction policy;
- provider finish reason;
- retry/watchdog budget;
- cancellation/close state;
- terminal error state.

Automatic continuation MUST never bypass tool result persistence, terminal event emission or stop policies.

## Progress and recovery

Each request exposes `request_started`, `response_started`, `message_delta`, `tool_args_receiving`, `tool_batch_finished`, `completed`, `failed`, `stopped` progress. Watchdog timers may repair only through bounded retry policy; retry exhaustion enters a terminal error and returns the Chat to user-input state.

Context-limit stop MUST reuse the safe continuation boundary. It MUST not cancel an in-flight provider stream or tool batch unless cancellation is explicitly requested.

## Scenario requirements derived from current tests

- Soft-stop request is accepted only while request/tool/AgentLoop work is active; repeated request toggles it off.
- A blocked automatic submit still executes its tool-reset callback, finalizes once, and performs no provider request.
- Manual submit after a completed soft stop proceeds normally.
- Context-limit targets support absolute and relative forms; unavailable usage fails closed.
- Reaching a context target while busy requests one-shot soft stop; reaching it while idle blocks automatic submit or converts tool completion to a user-ready boundary.
- Watchdog automatic repair has a bounded retry budget (current evidence: three consecutive retries) and resets on manual submit; the target MUST make the budget configurable rather than hard-code it as a universal value.

Evidence: `chat_soft_stop_test.lua`, `chat_context_limit_stop_test.lua`, `chat_request_watchdog_retry_limit_test.lua`.

## Submit intent and idempotency

A submit intent contains immutable `intent_id`, session/turn identity, kind, expected session generation, captured input/context revision and configuration snapshot ID. The orchestrator accepts an intent only at a legal state boundary. Replaying the same `intent_id` returns the existing decision/request; it never sends a duplicate provider request.

Manual submit has precedence over queued automatic continuation at the same ready boundary and invalidates that automatic intent. Retry creates a new request generation linked to the failed request, not a new manual user turn. Regenerate preserves the selected user boundary and archives/supersedes the prior assistant attempt according to history policy.

## Continuation decision table

The decision is a pure function over a committed request/tool-batch/session snapshot:

| Condition in precedence order | Decision |
| --- | --- |
| session closed or hard-cancelled | terminate/cancel; no continuation |
| terminal non-retryable provider/runtime failure | fail current request; return session to declared failed/waiting boundary |
| soft stop or reached context-stop boundary | wait for user after current durable work |
| incomplete/unpaired tool calls/results | repair/fail; never submit malformed pairing |
| completed tool batch and AgentLoop permits next iteration | submit exactly one automatic continuation |
| retryable failure and retry budget available | schedule one retry with backoff and new request generation |
| compaction required and permitted | execute one history compaction transaction, then reconsider from new session generation |
| otherwise | wait for user / complete turn |

A durable continuation key `(session_generation, source_request_id, tool_batch_id|none, decision_kind)` prevents duplicate decisions after callback races or recovery.

## Error and retry policy

Errors normalize to `configuration`, `authentication`, `permission-policy`, `rate_limited`, `quota`, `context_limit`, `invalid_request`, `provider_unavailable`, `network`, `timeout`, `protocol`, `tool`, `persistence`, `cancelled`, or `internal`. Tool permission prompts are removed; `permission-policy` means an invariant/policy violation, not user approval.

Retry eligibility is declared by error code plus provider/request metadata. Authentication, invalid configuration/request, unsupported protocol and persistence corruption are not automatically retried. Rate/network/timeout/provider-unavailable may retry with bounded exponential/backoff policy and optional provider retry hint. Context-limit retry is allowed only after a deterministic compaction/truncation action changes the request snapshot. Every retry delay is cancellable.

Watchdog detects absence of expected progress; it does not classify arbitrary long tool execution as provider stall. Progress types that reset/advance watchdog timing are declared per request phase. Retry budget and watchdog budget are separate fields but share the terminal decision boundary.

## Persistence/event order

For provider completion: normalize terminal payload -> commit assistant/tool-call/usage state -> emit request terminal -> create/execute ToolBatch if present -> commit results -> emit batch terminal -> persist continuation decision -> schedule next intent or ready projection. Failure to persist a required boundary stops continuation and yields `persistence` failure.

Executable submit/continuation/retry/race fixtures are normative in `../../runtime-fixture-contract.md`.
