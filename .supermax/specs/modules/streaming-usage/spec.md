---
title: SuperMax Streaming and Usage Normalization
created: 2026-08-02
updated: 2026-08-02
doc_role: target-module-spec
authority: draft
status: partial
baseline: ../modules/http-transport/spec.md
---

# Contract

Protocol adapters MUST emit one normalized stream model:

- `response_started`;
- text/content delta;
- reasoning delta when supported;
- tool-call start and argument delta;
- usage update;
- provider error;
- finish reason;
- `response_completed`.

A response containing only tool calls is valid and MUST enter tool-batch execution without requiring a text delta. Partial tool arguments MUST be accumulated by stable call ID and validated before execution.

## Usage

Adapters MUST normalize input/output/total tokens when the provider supplies them and record unknown values explicitly. Context percentage is derived from the configured model context limit and MUST be persisted with the session status snapshot. Token source precedence MUST be stable across UI, history and retry paths.

Normalized usage snapshot:

```yaml
input_tokens: integer|null
output_tokens: integer|null
total_tokens: integer|null
cached_input_tokens: integer|null
cache_creation_input_tokens: integer|null
reasoning_tokens: integer|null
tool_tokens: integer|null
provider_reported_total: integer|null
context_limit: integer|null
context_percent: integer|null
source: provider_final|provider_delta|local_estimate|restored
final: true|false
updated_at: integer
```

Rules:

- Provider-reported fields are authoritative for the request fields they cover. A local estimate fills unknown fields only and is marked `source: local_estimate`.
- `total_tokens` equals provider-reported total when supplied; otherwise it is computed only when all required components are known. Unknown is `null`, never zero.
- Streaming updates are monotonic per request generation unless the provider explicitly sends a corrected final snapshot; final correction replaces prior provisional values and is traceable.
- Retries have separate request usage and one session aggregate. Failed/cancelled attempts remain auditable and are not silently charged to the successful attempt's response snapshot.
- Context percentage uses `(effective_context_tokens / context_limit) * 100`, rounded by one declared runtime rule and clamped only for display. The raw count remains available when over limit.
- Session restore reads persisted normalized usage; it MUST NOT re-derive from rendered UI or compatibility adapter fields.

## Context-limit configuration

Model context limits resolve in this order:

1. Explicit project provider/model declaration.
2. Mother-repository exact model declaration.
3. Declared anchored model pattern, ordered by specificity.
4. Unknown (`null`).

Dynamic provider metadata may update a declaration only through a validated configuration/cache record. Unknown context limit disables percentage/automatic context-stop decisions and produces an unavailable diagnostic; it does not assume a universal default.

## Billing and quota projection

Billing/quota is not conversation token usage. It is an optional provider projection:

```yaml
provider_id: string
balance: number|null
currency: string|null
subscription:
  used: number|null
  remaining: number|null
  total: number|null
refreshed_at: integer|null
stale: true|false
error: string|null
```

Quota adapters such as current `newapi`, `sub2api`, or `deepseek` implementations are compatibility evidence, not additional LLM protocols. Provider IDs may select different quota backends while the LLM provider still resolves to one of the four supported protocols. Billing failure is isolated from request/session success and only changes status projection.

## Provider isolation

SSE, JSON streaming, Gemini native stream envelopes, Anthropic content blocks and Responses items are adapter details. The orchestrator consumes only normalized events and MUST tolerate provider-specific optional fields being absent. Exact request/stream/usage fixtures are defined in `../../protocol-fixture-contract.md`; spine/lualine fixtures are defined in `../../runtime-fixture-contract.md`.
