---
title: OpenAI Responses Adapter 稳定规格
created: 2026-09-15
updated: 2026-10-09
type: source
doc_role: spec
authority: stable
status: stable
capability: openai-responses-adapter
validation:
  specification: passed
  automated: passed
  live: passed
  human: passed
sources:
  - lua/maxa/adapters/http/openai_responses.lua
  - lua/maxa/adapters/http/openai_responses_extensions/deepseek.lua
  - lua/maxa/adapters/http/init.lua
  - lua/maxa/adapters/behavior.lua
  - lua/maxa/utils/tool_transformers.lua
  - lua/maxa/session/llm_error_recovery.lua
  - lua/plugins/ai.lua
  - https://developers.openai.com/api/docs/guides/function-calling
  - https://developers.openai.com/api/docs/guides/structured-outputs
  - https://developers.openai.com/api/docs/guides/reasoning
  - https://api-docs.deepseek.com/guides/responses_api/
  - https://api-docs.deepseek.com/api/create-response/
confidence: high
---

# OpenAI Responses Adapter

## Purpose And Boundary

Own Maxa AI's Chat/LLM Responses protocol and temporary historical tool-image serialization; exclude GenAI image generation/editing, text-to-speech/video, generic MCP media transport and session retry/compact policy after error normalization.

[Runtime Plugin Entrypoints](./plugin-entrypoints.md) owns gateway composition, endpoint registration, model lists, Anthropic Messages gateway construction, endpoint/model choice/quota normalization and protocol dispatch. This spec SHALL NOT duplicate or activate Anthropic behavior. Configured DeepSeek MAY use that factory with `protocol="openai_responses"`; this spec owns Responses behavior, with compatibility explicitly composed through the decorator.

## Standard Protocol Ownership

### Requirement: Official Responses behavior has one production owner

`lua/maxa/adapters/http/openai_responses.lua` SHALL solely own official request/message serialization, function-tool conversion and call/output identity, streamed/non-streamed parsing, official reasoning continuation, wire-error decoding, temporary historical tool-image conversion and tool-argument lifecycle mapping. Only this adapter and an explicitly composed extension may parse their respective wire events.

The standard adapter SHALL NOT inspect/branch by provider, discover extensions or implement DeepSeek events/state; metadata alone SHALL NOT activate compatibility. Production source SHALL NOT contain/load a separate Responses behavior module, generic adapter ownership of Responses identity/strict schemas, generic tool-transformer Responses schema transformation, session-recovery raw Responses decoding, provider auto-detection, compatibility registry, forwarding module or old/new dual path. Post-setup patches and provider switches SHALL NOT participate in the standard wire contract.

## Function Tool Serialization

### Requirement: Standard function tools use local validation and non-strict schemas

Standard function tools SHALL use flat `type`, `name`, `description`, `parameters` and explicit `strict=false`. Deep-copy parameters while preserving source required/null types, bounds, defaults, alternatives and `additionalProperties`; do not force properties into required, add null, close source-open objects or discard constraints. Shared local raw-argument validation and target business guards reject invalid calls before execution; best-effort generation is not validation evidence.

Sorting, canonical call identity/history, reasoning/output parsing and provider-native non-function tools remain unchanged. DeepSeek's explicit decorator omits unsupported strict fields but retains common local validation; the standard adapter contains no provider branch.

### Requirement: Only documented open JSON properties use encoded strings

Preserve the existing `fire.data` encoded-object-string boundary, copy-on-write schema and handler decoding. Add neither strict-only hidden decoders nor arbitrary open-object rewrites. `run.args` and member args retain string/string[]/null alternatives; decoded tool objects remain target-owned, not direct wrapper objects or restored JSON injection. Check source constraints locally; obsolete strict-only schema rejection rules no longer apply.

### Requirement: Unified execution title serialization

Source-preserving serialization requires `title`/`command` for standalone `run`, outer `title`/`runs` for `multirun`, and only `command` as required on members, with no `label`. Source-optional member `title`/`mode`/`async`/other fields SHALL remain omittable; null follows source types. Standalone title remains mandatory. Prepared/internal representations SHALL NOT mutate source schema trees. Runtime validates args/opts/target semantics; `json_patches` remains absent.

## Message Ordering And Call Identity

### Requirement: Initial system prefix becomes instructions

Initial contiguous system messages SHALL become top-level `instructions`; system messages after a non-system message SHALL fail locally. Preserve conversation order across input messages, reasoning items, function calls/outputs and image parts.

### Requirement: Server call identifiers remain exact and distinct

Preserve server-issued `id` and `call_id` as distinct exact values; outputs SHALL reference the exact `call_id`. The adapter SHALL NOT synthesize, normalize, prefix, copy or overwrite either identity. Missing/empty required `call_id` SHALL fail before request dispatch.

## Reasoning Continuity

### Requirement: Official stateless reasoning is replayed without raw-reasoning claims

For configured stateless OpenAI operation, retain official continuation reasoning items, including available summary/encrypted content, and replay in protocol-valid order. The adapter SHALL NOT treat provider plaintext reasoning events as official OpenAI events or claim OpenAI exposes raw reasoning text.

Reasoning/request state SHALL be adapter-instance-local, reset at request start, terminal response and adapter exit, and never shared at module level across adapters/Chats.

## Output Parsing

### Requirement: Streamed and non-streamed parsing is item-complete

Both modes SHALL process every item in order, concatenate assistant `output_text` and collect official reasoning/function calls even when reasoning precedes text:

| Received call | Required handling |
| --- | --- |
| `status="completed"` | Only executable status. Deduplicate by exact `call_id` first, then exact `id`, without rewriting; item plus terminal representations execute once. |
| `in_progress`, `incomplete`, malformed or duplicate | SHALL NOT execute handlers. |
| Call in `response.incomplete`, incomplete non-streamed item or streamed partial arguments | Preserve canonical fields, partial arguments and incomplete status for Chat-owned bounded rejection/correction; neither drop the call nor turn the terminal into an ordinary request error. |
| Missing name, `id` or `call_id` | Reach Chat validation without parser exception; request serialization still rejects unreplayable calls before the next request. |

## Error And Lifecycle Normalization

### Requirement: The adapter normalizes Responses wire errors

The HTTP adapter SHALL support optional `handlers.response.parse_error(self, data) -> string|nil`. Responses SHALL use one private decoder for Chat parsing errors and classification strings: recognize official `error`, `response.failed`, `response.incomplete` and nested error/incomplete details; return a stable string containing available `code`, `type`, `message`, `param`, `reason`, or nil for malformed/non-error/terminal-marker input.

Session recovery consumes this normalized result and generic HTTP failures; it SHALL NOT decode Responses JSON/SSE or name wire events.

### Requirement: Tool-argument progress is mapped at the adapter boundary

Official function-item/argument events SHALL map to existing `MaxaAIToolCallArgumentsStarted`, `MaxaAIToolCallArgumentsDelta`, `MaxaAIToolCallArgumentsDone`, with bounded applicable Chat/item/call/index/length facts. Watchdog/status/UI/lifecycle consumers SHALL consume only normalized `MaxaAI*` events, never parse Responses wire events.

## Historical Tool Images

### Requirement: Tool images are temporary request inputs only

For non-expired `_meta.image` and `_meta.images[]` tool results, request construction SHALL keep `function_call_output.output` textual and append corresponding `input_image` parts to the following user input. Convert only a copied request representation; never persist image parts in Chat history. Skip expired/missing base64 payloads. This replay-only behavior SHALL NOT route, generate, edit or persist GenAI media requests.

## Explicit DeepSeek Extension

### Requirement: DeepSeek compatibility requires explicit composition

`lua/maxa/adapters/http/openai_responses_extensions/deepseek.lua` SHALL export exactly `extend(base_factory) -> decorated_factory` (both functions). The decorated factory creates one base adapter, captures required base handlers, applies only documented DeepSeek differences and returns it; mutable state remains adapter-instance-local.

Activation requires `lua/plugins/ai.lua` to declare DeepSeek's `extend` in `opts.maxa.providers.deepseek.llm.openai_responses` and provider configuration to compose it with the base factory. The extension SHALL NOT self-register, modify the standard module, inspect provider metadata for activation or create a generic extension chain. `backend.provider="deepseek"` is descriptive only.

### Requirement: DeepSeek request surface matches documented support

The decorator SHALL send full history for the stateless API and apply:

| Request surface | Obligation |
| --- | --- |
| Unsupported state/cache/metadata/include/background/truncation/stream-options fields | Omit. |
| `reasoning.summary`, `text.verbosity` | Do not expose as effective controls. |
| Documented `reasoning.effort`, `temperature`, `top_p`, `max_output_tokens`, `top_logprobs`, `text.format`, function `tools`, `tool_choice` | Preserve. |
| Tools on this Chat path | Emit only documented function tools; omit unsupported OpenAI built-ins, including standard web search. |

Gateway base configuration SHALL preserve DeepSeek-supported sampling fields before the decorator removes only documented unsupported fields.

### Requirement: DeepSeek tools do not claim OpenAI strict enforcement

Deep-copy and flatten function tools into `type`, `name`, `description`, `parameters`, without `strict` or OpenAI Structured Outputs normalization. Reject malformed argument JSON before dispatch; decoded semantic validation remains target builtin/MCP-owned. The extension SHALL NOT coerce/fabricate arguments or add a second semantic schema-validation framework.

### Requirement: DeepSeek plaintext reasoning is converted and continued

The decorator SHALL:

- Serialize prior plaintext reasoning as reasoning items with `reasoning_text` parts, omitting OpenAI summary/encrypted fields; retain required reasoning around tool calls.
- Parse streamed delta/done and completed plaintext items, deduplicating overlaps; attach accumulated reasoning to tool-only results to preserve full-history reasoning/call/output order.
- Clear extension state at terminal response and adapter exit; delegate standard visible text/completed calls/usage/terminal status/common errors to captured standard handlers.

## Validation Evidence

Recorded evidence remains scoped to its original checks; this contract does not extend it to GenAI media generation.

| Behavior group | Passed evidence and limits |
| --- | --- |
| Local argument validation | Focused local/schema/prepare/wire tests, DeepSeek provider-boundary checks and fresh public calls omitting optional fields. Human implementation review `not-run` is historical. |
| Unified execution dispatch | 18 focused adapter checks and fresh-Chat `run`/`multirun` wire calls. Human implementation review `not-run` is historical. |
| Accepted focused automated validation | Standard behavior; strict schema conversion (historical, not current wire behavior) and local rejection; exact ID/call-ID replay; item-complete parsing; completed-only execution; incomplete/partial call handoff to Chat validation; adapter-normalized recovery; temporary tool images; DeepSeek function schemas, explicit wiring and exactly-once plaintext reasoning continuation. |
| Fresh configured-process validation | Standard/decorated factory wiring, reachable `parse_error`, DeepSeek omissions and wire-only `call.params` narrowing without source mutation. |
| Live configured gateways | Standard and DeepSeek tool continuations. |

Permanent focused automated, configured-process, standard-gateway and DeepSeek continuation states remain `passed` for those recorded scopes; human specification review is `passed`. The review/provenance notice governs later batch review without erasing historical gaps.

## Source Trace

- Standard owner and explicit extension: the two `openai_responses` source paths named in their ownership requirements above.
- Registration/composition: `lua/maxa/adapters/http/init.lua`, `lua/plugins/ai.lua`.
- Session recovery consumer: `lua/maxa/session/llm_error_recovery.lua`.
- Chat builtin source schemas: [Chat Builtins](./chat-builtins.md).
