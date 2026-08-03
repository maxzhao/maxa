---
title: SuperMax Tool Runtime
created: 2026-08-02
updated: 2026-08-02
doc_role: target-module-spec
authority: draft
status: partial
baseline: ../modules/tools-agent-loop/spec.md
---

# Contract

MCP and Skill tools are built-in runtime capabilities. Tool execution MUST use one orchestrator path for valid, invalid, failed, cancelled and expired calls.

## Call lifecycle

`declared → received → validated | invalid → queued → running → succeeded | failed | cancelled | expired → persisted → projected`.

- Schema and JSON arguments are validated before execution.
- Invalid calls produce a standard tool error result and still participate in batch completion.
- Tool call IDs are stable; missing IDs receive runtime-generated IDs with provenance.
- Tool calls and results are paired before the next provider request.
- Tool batches expose a completion barrier before continuation is decided.

## Execution policy

All configured MCP/Skill tools execute automatically without user authorization or approval. This is an explicit product policy, not an implicit bypass. The runtime MUST still record tool name, parameters metadata, start/end, status, error, cancellation, timeout and owner session.

## Result and UI separation

Internal result content, persisted result content, and Chat display summary are separate projections. TTL cleanup MUST NOT remove data needed to satisfy provider pairing or durable history rules. Async tasks created by a tool inherit the owning session cancellation scope.

## Tool definition

```yaml
id: server-id/tool-name
name: tool-name
description: string
input_schema: object
execution:
  mode: sync|async
  timeout_ms: integer|null
  cancellable: true|false
  side_effect: none|read|write|process|network|external
result:
  durable: true|false
  display: summary|markdown|hidden
```

Registry IDs are unique and project/configuration-snapshot scoped. Duplicate IDs fail registration unless they are the same immutable definition hash. Tool schemas are normalized once without weakening required fields. Provider-specific schema adaptation happens on a copy.

## Batch and concurrency policy

Tool calls preserve provider order as `ordinal`. Default execution is sequential. A project/runtime concurrency value greater than one may run independent calls concurrently, but persisted provider results are ordered by original ordinal unless the protocol requires another explicit ordering. A call may declare dependency IDs; cycles fail the batch before execution.

The completion barrier opens only after every accepted call is terminal and every provider-facing result is persisted. `ToolBatchFinished` is emitted once. The request orchestrator then chooses continuation; tool handlers cannot directly submit the Chat. Batch failure policy is explicit: invalid/failed calls normally produce results and allow independent calls to continue, while configuration corruption or cancellation may stop remaining calls.

## Async and retained results

An async handler returns a runtime task identity, not an untracked callback. Poll/get/cancel operations validate owner session and task generation. Completion is compare-and-set; duplicate or late completion is ignored with a diagnostic.

TTL manages auxiliary tool-result payload availability:

- `discard`: remove auxiliary content when no durable/protocol pairing depends on it.
- `defer`: extend availability by declared rounds.
- `keep`: retain for the session.
- `persist`: retain through compaction/recovery according to history policy.

The compact display summary may expire independently. The provider-facing result and durable trace remain until pairing/history retention permits removal.

## Failure contract

Validation, unavailable tool, handler exception, timeout, non-zero process exit, network failure, cancellation and expired auxiliary payload are distinct error codes. Error messages redact secrets and bound output size while preserving exact command/path/tool identifiers required for repair. No failure path opens an approval prompt.

Required executable fixtures are in `../../runtime-fixture-contract.md`.
