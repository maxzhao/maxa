---
title: SuperMax Four-Protocol Fixture Contract
created: 2026-08-02
updated: 2026-08-02
doc_role: validation-contract
authority: draft
status: partial
sources:
  - modules/provider-contract/spec.md
  - validation-matrix.md
  - ~/.local/share/nvim/lazy/codecompanion.nvim/lua/codecompanion/adapters/http/openai.lua
  - ~/.local/share/nvim/lazy/codecompanion.nvim/lua/codecompanion/adapters/http/openai_responses.lua
  - ~/.local/share/nvim/lazy/codecompanion.nvim/lua/codecompanion/adapters/http/anthropic.lua
  - lua/util/hooks/adapter_openai_responses_streaming_tools_test.lua
  - https://developers.openai.com/api/reference/resources/chat/subresources/completions/methods/create
  - https://github.com/openai/openai-openapi/blob/main/openapi.yaml
  - https://github.com/anthropics/anthropic-sdk-typescript/blob/main/src/resources/messages/messages.ts
  - https://ai.google.dev/api/generate-content
confidence: high
---

# Purpose

Define the protocol-level fixture files and assertions required before `provider-contract` can move from `partial`. Fixtures test protocol adapters against the normalized runtime model; they do not instantiate CodeCompanion adapters.

## Common fixture envelope

Each fixture SHALL contain:

```yaml
id: protocol-scenario-id
protocol: openai_chat|openai_responses|anthropic_messages|gemini
mode: streamed|non_streamed
request:
  normalized_messages: []
  normalized_tools: []
  provider_options: {}
  expected_body: {}
response:
  chunks: []
  expected_events: []
  expected_message: {}
  expected_tool_calls: []
  expected_usage: {}
  expected_terminal: completed|failed|cancelled|incomplete
```

Comparison rules:

- JSON object key order is irrelevant; array order is significant.
- Empty JSON objects MUST remain objects, not arrays.
- Omitted optional fields and explicit `null` are distinct when the provider protocol distinguishes them.
- Stream chunks SHALL be fed one at a time. The adapter MUST NOT depend on receiving a concatenated transcript.
- Every scenario ends in exactly one normalized terminal event.
- Tool arguments are accumulated as UTF-8 bytes/text and decoded only at the tool-runtime validation boundary.
- Provider payload objects never become persisted normalized messages.

## OpenAI Chat Completions

### Request mapping

Target endpoint suffix: `/chat/completions`.

- Normal messages map to `messages[]` with `role` and `content`.
- Assistant tool calls map to `tool_calls[]` containing only `id`, `type`, and `function`.
- Tool results map to `{role:"tool", tool_call_id, content}`.
- Supported image input maps to an `image_url` content part with a `data:<mime>;base64,<data>` URL.
- Nonempty tools map to `tools`; absent/empty tools omit the field.
- Streaming requests set `stream=true` and request usage inclusion when the endpoint supports `stream_options.include_usage`.

Source evidence: pinned `openai.lua:53-190`.

### Streaming normalization

- `choices[].delta.role/content` yields normalized assistant deltas.
- `choices[].delta.tool_calls[]` is keyed by protocol `index`; later fragments append only `function.arguments`.
- A provider call ID is required by the target. A compatibility-only synthesized ID may be accepted only when the endpoint omits it, and the event MUST mark `id_source="synthetic"`.
- Usage may arrive in a final chunk with no choices; it updates usage without producing assistant content.
- `[DONE]` or transport EOF is not completion by itself when an earlier typed failure exists.

Official-source validation: OpenAI API reference retrieved through Context7 (`/websites/developers_openai_api_reference`) verifies the `/v1/chat/completions` tool shape, streamed `chat.completion.chunk` deltas, `stream_options.include_usage`, and finish reasons including `stop`, `length`, `tool_calls`, `content_filter`, and legacy `function_call`. Usage includes `prompt_tokens`, `completion_tokens`, `total_tokens`, and optional completion details such as reasoning tokens. Source evidence: pinned `openai.lua:192-319`; target tightens ID observability.

### Required fixtures

- `openai-chat/text-stream`
- `openai-chat/text-nonstream`
- `openai-chat/tool-arguments-fragmented`
- `openai-chat/multiple-tool-calls-interleaved`
- `openai-chat/tool-result-continuation`
- `openai-chat/final-usage-with-empty-choices`
- `openai-chat/malformed-json`
- `openai-chat/http-error`
- `openai-chat/cancel-and-late-delta`

## OpenAI Responses

### Request mapping

Target endpoint suffix: `/responses`.

- System messages concatenate into `instructions`; non-system records map to `input`.
- Reasoning maps to `type:"reasoning"` with optional summary and encrypted content.
- Images map to `input_image`; adjacent same-user text may share one content list.
- Assistant calls map to `type:"function_call"` with `id`, `call_id`, `name`, and encoded `arguments`.
- Tool results map to `type:"function_call_output"` with `call_id` and `output`.
- Function schemas pass recursive strict-mode normalization; provider-native tools remain explicit adapter capabilities.

Source evidence: pinned `openai_responses.lua:104-273` and current strict-schema hook tests.

### Streaming normalization

- `response.created` establishes response identity.
- `response.output_text.delta` yields assistant text.
- `response.reasoning_summary_text.delta` yields reasoning delta.
- `response.completed` may contain completed function calls without text; this is a valid tool-only response.
- `event:error`, `response.failed`, and `response.incomplete` are typed terminal failures/incomplete outcomes and MUST NOT be converted to success by later EOF/exit callbacks.
- Usage is read from the completed response when supplied.

Official-source validation: OpenAI's official OpenAPI (`/openai/openai-openapi`) verifies ordered SSE events with `sequence_number`, including `response.created`, `response.in_progress`, output-item/content events, `response.output_item.done`, and terminal `response.completed`/`response.incomplete`. Response status is one of `queued`, `in_progress`, `completed`, `failed`, `cancelled`, or `incomplete`; terminal event type and embedded response status must agree or produce a protocol error. Source evidence: pinned `openai_responses.lua:319-510`; current Responses streaming/error hook tests.

### Required fixtures

- `openai-responses/text-stream`
- `openai-responses/reasoning-and-text`
- `openai-responses/tool-only-completed`
- `openai-responses/multiple-function-calls`
- `openai-responses/function-call-output-continuation`
- `openai-responses/strict-nested-schema`
- `openai-responses/event-error`
- `openai-responses/response-failed`
- `openai-responses/response-incomplete`
- `openai-responses/cancel-and-late-event`

## Anthropic Messages

### Request mapping

Target endpoint suffix: `/messages`.

- Nonempty system messages map to `system` text blocks and are removed from `messages`.
- String user/assistant content maps to text blocks.
- Empty user continuation maps to an explicit nonempty placeholder selected by target configuration.
- Assistant tool calls map to `tool_use` blocks with decoded object input.
- Tool results use user-role `tool_result` blocks with `tool_use_id`, content, and `is_error`.
- Consecutive same-role messages and adjacent tool results are consolidated without losing call identity.
- Thinking blocks preserve thinking text and signature only when the configured model/protocol capability requires round-trip retention.
- Image input uses base64 source blocks only when provider/model vision capability is enabled.

Source evidence: pinned `anthropic.lua:98-348`.

### Streaming normalization

- `message_start` establishes role and initial usage.
- `content_block_start` creates thinking or tool-use accumulator by block index.
- `content_block_delta` maps text/thinking/signature deltas and appends `partial_json` to the matching tool input.
- `message_delta` updates output usage and stop reason.
- Non-stream `message` content blocks follow the same normalized output path.
- Cache creation/read input token fields contribute to normalized input/cache usage without double counting.

Official-source validation: the official Anthropic TypeScript SDK (`/anthropics/anthropic-sdk-typescript`) verifies required `model`, `messages`, `max_tokens`; optional `system`, `stream`, `thinking`, `tools`, and `tool_choice`; stream events `message_start`, `content_block_start`, `content_block_delta`, `content_block_stop`, `message_delta`, and `message_stop`; `input_json_delta.partial_json`; and thinking/signature deltas. Ping is a keepalive and produces no normalized content. SDK stream error/abort is terminal. Stop reasons include `end_turn`, `max_tokens`, `stop_sequence`, `tool_use`, `pause_turn`, `refusal`, and `model_context_window_exceeded`. Usage includes input/output and nullable cache creation/read fields plus provider detail metadata. Source evidence: pinned `anthropic.lua:400-516`.

### Required fixtures

- `anthropic/text-stream`
- `anthropic/text-nonstream`
- `anthropic/thinking-signature-roundtrip`
- `anthropic/tool-input-partial-json`
- `anthropic/multiple-tool-use-results`
- `anthropic/cache-usage`
- `anthropic/provider-error`
- `anthropic/cancel-and-late-block`

## Gemini native API

### Official validation status

This is a target contract, not retained CodeCompanion evidence. On 2026-08-02, Context7 successfully resolved high-reputation official Gemini documentation (`/websites/ai_google_dev_api`) sourced from `https://ai.google.dev/api` and `https://ai.google.dev/api/generate-content`. It verified native endpoints, request/response fields, function call/result parts, prompt blocking and usage metadata. Direct `web-fetch` remained unavailable, but it is no longer a protocol-field blocker because official-source documentation was retrieved through Context7.

### Request mapping

- Non-stream endpoint is `POST https://generativelanguage.googleapis.com/v1beta/{model=models/*}:generateContent`; streaming uses `:streamGenerateContent` and SSE. The target never uses `/v1beta/openai/chat/completions`.
- `contents[]` is required and contains native `Content` records with `role` and `parts[]`.
- System records map to text-only `systemInstruction`.
- Tool declarations map to `tools[].functionDeclarations[]`. A `FunctionDeclaration` contains `name`, `description`, and one validated parameter schema representation (`parameters` or `parametersJsonSchema`); response schema fields are passed only when supported by target capability policy.
- `toolConfig`, `safetySettings`, `generationConfig`, `cachedContent`, service tier and storage options are allowlisted provider options, never arbitrary passthrough.
- A native `Part` uses exactly one data union member. Target-supported members are `text`, `inlineData`, `fileData`, `functionCall`, and `functionResponse`; executable-code/server-tool unions require separately declared target capabilities and are not enabled implicitly.
- `inlineData` contains `mimeType`/wire-equivalent MIME field and base64 data according to the selected API serialization. Fixture snapshots use the exact REST JSON spelling returned by the official schema.
- `functionCall` contains optional `id`, required `name`, and object `args`. If `id` is absent, the runtime creates a stable ID with `id_source="synthetic"` and pairs the later response by runtime ID/name/ordinal.
- `functionResponse` contains optional/provider call `id`, `name`, object `response`, and optional response parts/continuation scheduling fields. The target sends only fields required by the call/result and configured native capability.

### Response and streaming mapping

- Every `GenerateContentResponse` may contain `candidates[]`, `promptFeedback`, `usageMetadata`, `modelVersion`, `responseId`, and `modelStatus`.
- Candidate content parts map text/function calls by candidate and part ordinal; candidate `finishReason` and `safetyRatings` are preserved in normalized terminal metadata.
- `promptFeedback.blockReason` means the prompt was blocked and no candidates are returned. This is a typed provider failure, not successful empty content.
- An empty candidate set without block feedback is an explicit `empty-candidates` protocol outcome and not silent success.
- Each `streamGenerateContent` SSE response envelope is processed independently and may add candidate parts, finish/safety metadata and usage. Repeated cumulative fields are de-duplicated by response/candidate/part identity; text is appended only according to the documented stream representation captured by fixtures.
- Function-call parts yield normalized calls with stable runtime identity. Object `args` is encoded deterministically for the provider-neutral tool boundary.
- Usage maps `promptTokenCount`, `cachedContentTokenCount`, `candidatesTokenCount`, `toolUsePromptTokenCount`, `thoughtsTokenCount`, and `totalTokenCount`, retaining modality detail arrays and service tier as provider metadata.
- HTTP/API errors, SSE decode errors, prompt blocks, safety termination, cancellation and late envelopes map to typed normalized outcomes and exactly one terminal event.

### Required fixtures

- `gemini-native/text-stream`
- `gemini-native/text-nonstream`
- `gemini-native/system-instruction`
- `gemini-native/function-call-response`
- `gemini-native/multiple-function-calls`
- `gemini-native/image-part`
- `gemini-native/usage-metadata`
- `gemini-native/safety-block`
- `gemini-native/empty-candidate`
- `gemini-native/api-error`
- `gemini-native/cancel-and-late-envelope`

## Acceptance gate

`provider-contract` remains `partial` until:

1. Official protocol documentation sources are recorded and reviewed for drift at implementation/acceptance time. Core Gemini native names are verified.
2. Every required fixture exists as data plus an executable replacement-adapter test.
3. Request-body and normalized-event snapshots pass.
4. Error, cancellation, late-callback and tool-only cases terminate exactly once.
5. No fixture imports CodeCompanion modules.
