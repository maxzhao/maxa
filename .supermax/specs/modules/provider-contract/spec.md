---
title: SuperMax Four Protocol Provider Contract
created: 2026-08-02
updated: 2026-08-02
doc_role: target-module-spec
authority: draft
status: partial
baseline: ../modules/http-transport/spec.md
---

# Provider definition

A provider is a compact project configuration record, not the full CodeCompanion adapter schema. Current source evidence: `make_llm_gateway_adapter` validates `name`, `protocol`, and `base_url`, normalizes a trailing slash and optional quota, dispatches by protocol, then registers quota (`lua/plugins/ai.lua:595-668`).

```lua
{
  id = "gateway_name",
  protocol = "openai_chat|openai_responses|anthropic_messages|gemini",
  base_url = "...",
  api_key = function() ... end,
  model = "...",
  model_options = { has_vision = true, has_function_calling = true, can_reason = true },
  request_options = {},
}
```

The runtime supplies common gateway behavior: headers, proxy, retries, curl/HTTP lifecycle, model selection, token accounting and normalized errors. Provider records may override only protocol-supported fields. Gateway-specific `supermax.compact`/`summary` blocks replace defaults as whole values rather than deep-merge missing fields (`lua/plugins/ai.lua:351-357,429-440,535-546`).

## Current evidence and target gap

The current gateway factory has concrete implementations only for `openai_responses` and `anthropic_messages`; unsupported factory values fail (`lua/plugins/ai.lua:658-665`). `ai.lua` configures CodeCompanion's adapter named `gemini` with `GEMINI_API_KEY` and default `gemini-2.5-pro` (`lua/plugins/ai.lua:1325-1335`), but pinned CodeCompanion `v18.7.0` implements that adapter through Google's OpenAI-compatible `/v1beta/openai/chat/completions` endpoint and delegates message/tool behavior to the OpenAI adapter (`adapters/http/gemini.lua:65-172`). It is therefore NOT Gemini native API evidence. OpenAI Responses removes configured unsupported fields and sets a daily/project/model prompt-cache key (`lua/plugins/ai.lua:406-518`). Anthropic gateway model choices must replace—not merge—the upstream official list (`lua/plugins/ai.lua:522-587`). The target MUST add first-class OpenAI Chat Completions and Gemini native implementations to the compact provider model with equivalent validation/fixtures; Gemini native is a new target adapter, not a retained implementation.

## Protocol capability matrix

| Capability | OpenAI Chat Completions | OpenAI Responses | Anthropic Messages | Gemini native API |
| --- | --- | --- | --- | --- |
| Normalized messages | `messages` | `input`/response items | `system` + `messages` content blocks | `systemInstruction` + `contents` |
| Tool declaration | function tools | function tools / strict schema | `tools.input_schema` | function declarations |
| Tool call/result | assistant `tool_calls` / tool role | function-call items / function-call-output | `tool_use` / `tool_result` | `functionCall` / `functionResponse` |
| Streaming | SSE deltas | SSE response events; tool-only valid | native content-block events | native generate-content stream events |
| Usage | prompt/completion/total | input/output/total when supplied | input/output/cache when supplied | native prompt/candidate/total when supplied |
| Current SuperMax evidence | `openai_compatible` adapter path | gateway factory plus stream/schema hooks | gateway factory plus message/tool hooks | none; current adapter uses Gemini OpenAI-compatible endpoint |
| Target fixture status | absent | partial | partial | absent |

## Protocol adapters

- OpenAI Chat Completions: `/chat/completions` message/tool format and SSE normalization.
- OpenAI Responses: response input/items, function calls, tool-only streams, strict schema handling and response usage.
- Anthropic Messages: system separation, content blocks, tool use/result and native stream events.
- Gemini native API: `contents`, `systemInstruction`, `tools`, `functionCall/functionResponse`, native usage and stream event mapping.

Unsupported protocol names MUST fail configuration validation. Provider payloads MUST NOT become the core conversation model.

## Request and stream invariants

Detailed fixture schemas and required cases are defined in `../../protocol-fixture-contract.md`.

- OpenAI Chat Completions accumulates fragmented tool arguments by protocol index, separates usage-only chunks from content, and preserves tool-call identity through continuation.
- OpenAI Responses separates `instructions` from `input`, treats completed tool-only responses as valid, recursively normalizes strict function schemas, and gives typed error/incomplete events precedence over generic exit callbacks.
- Anthropic Messages separates system blocks, round-trips `tool_use`/`tool_result` identity, accumulates partial tool JSON by content-block index, and normalizes cache-aware usage without double counting.
- Gemini MUST use native `generateContent`/`streamGenerateContent` request and response shapes; the pinned OpenAI-compatible adapter is prohibited as the target implementation.
- Every adapter emits normalized start/delta/tool/usage/terminal events and exactly one terminal result. Cancellation invalidates later provider callbacks by request identity.

## Official protocol evidence

On 2026-08-02, direct `web-fetch` still timed out or exhausted available modes, but Context7 connectivity succeeded and returned high-reputation official sources:

- OpenAI API reference: `/websites/developers_openai_api_reference`.
- OpenAI OpenAPI: `/openai/openai-openapi`.
- Anthropic official TypeScript SDK: `/anthropics/anthropic-sdk-typescript`.
- Gemini official API reference: `/websites/ai_google_dev_api`.

These sources verified Chat Completions tool/stream/usage/finish fields; Responses ordered SSE/terminal status fields; Anthropic request/content-block/tool/usage/stop fields; and Gemini native endpoints, `contents`, `systemInstruction`, tools/function parts, candidates/prompt feedback and usage metadata. Exact verified mappings and source URLs are recorded in `../../protocol-fixture-contract.md`.

Official-source availability closes the prior Gemini field-evidence blocker. This module remains `partial` only because executable replacement fixtures/implementation do not yet exist and protocol drift must be checked again at acceptance time.
