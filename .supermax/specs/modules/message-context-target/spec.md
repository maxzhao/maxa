---
title: SuperMax Normalized Message and Context Model
created: 2026-08-02
updated: 2026-08-02
doc_role: target-module-spec
authority: draft
status: partial
baseline: ../modules/message-context/spec.md
---

# Contract

The runtime MUST maintain a provider-neutral conversation model. Supported roles/records include system, project, user, assistant, tool call, tool result, context fragment and image content. Provider adapters translate this model into protocol payloads.

## Context composition

A request context is composed in stable order from:

1. runtime system prompt;
2. target-project `.maxa/` rules and project prompt sources;
3. session protected prefix and loaded history items;
4. user message and explicit context;
5. assistant/tool history required for protocol pairing.

The composer MUST record source, precedence and truncation/compaction effects. Target-project-local `.maxa/` is the configuration and prompt authority; the development mother repository's `.supermax/` and unrelated global project state MUST NOT be silently injected.

## Invariants

- Tool call/result IDs and provider-neutral turn IDs are stable across retries and recovery.
- Images are content parts with explicit source/metadata and are normalized before provider encoding.
- Empty JSON objects remain objects, not arrays.
- Provider-specific system-message placement is an adapter concern.
- Context-only and empty submissions have explicit validation behavior.

## Normalized records

```yaml
message:
  id: string
  turn_id: string
  role: system|project|user|assistant|tool
  content: []
  visibility: visible|hidden
  provenance: {}
  created_at: integer
content_part:
  type: text|reasoning|image|tool_call|tool_result|context_ref
```

Part constraints:

- `text`: UTF-8 text plus optional language/media metadata.
- `reasoning`: content plus provider round-trip metadata kept separate from visible assistant text; retention follows provider/model policy.
- `image`: MIME type and runtime-owned payload/blob reference; temporary payload expiry cannot invalidate a message already committed for a request.
- `tool_call`: runtime call ID, optional provider ID/provenance, tool name and encoded arguments.
- `tool_result`: paired call ID, status and provider-facing content; user display is a separate projection.
- `context_ref`: stable context item ID and snapshot/hash, never an implicit live buffer pointer.

Provider response deltas are transient events. A durable assistant message is committed at a response/tool-call boundary and stores normalized parts, not raw provider envelopes. Retries reference the same user turn but create a new request and assistant attempt identity.

## Context items

Every context item has `id`, `kind`, `source`, `project_id`, `content` or blob reference, content hash, visibility, insertion time and optional refresh policy. Supported kinds include project rules, Skill context, file/buffer snapshot, diagnostics/symbols, URL/article, image, fragment and generated summary. Live sources are snapshotted before request composition; later source changes do not mutate an in-flight request.

Duplicate context is resolved by stable ID/content hash and declared precedence. Protected-prefix/history items are never silently dropped. Truncation/compaction records exact removed IDs/ranges and replacement summary provenance. A context item from another project is rejected unless an explicit transfer operation rebinds it with provenance.

## Submission validation

- Whitespace-only input with no new context is `empty-submit` and creates no request.
- Context-only submission is valid when at least one selected item contributes provider-visible content; a deterministic minimal user instruction is generated and marked synthetic.
- Automatic continuation may submit an empty visible user string only when complete paired tool results or a protocol-required continuation record exists.
- Missing/expired image payload, unpaired tool result, unresolved context source, prompt composition error or cross-project item blocks composition with an exact item/field diagnostic.
- Message/context composition is pure for one immutable session/configuration snapshot; adapters receive a deep immutable projection.

Protocol mapping fixtures are in `../../protocol-fixture-contract.md`; context/recovery/prompt fixtures are in `../../runtime-fixture-contract.md`.
