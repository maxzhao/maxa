---
title: GenAI Native MCP 与媒体工作流规格
created: 2026-06-28
updated: 2026-10-10
type: source
doc_role: spec
authority: stable
status: stable
capability: genai
validation:
  specification: passed
  automated: passed
  live: partial
  human: passed
sources:
  - lua/maxa/mcphub/native_servers/genai/
  - lua/plugins/ai.lua
  - lua/maxa/adapters/proxy.lua
  - abilities/genai/SKILL.md
  - abilities/genai/SYSTEM.md
  - abilities/genai/references/
confidence: high
---

# GenAI Native MCP And Media Workflows

## Purpose

Define media dispatch/defaults, independent media identity/capability settings, provider connection/proxy defaults and local image/audio/video results. `requested_size` records intent, not inspected dimensions. GenAI's `openai_responses_image_generation` media driver is separate from the Chat/LLM protocol below.

## Scope And Ownership

| Owner | Responsibility |
| --- | --- |
| `lua/maxa/mcphub/native_servers/genai/` | Four Native tools, global media defaults, capability resolution and media drivers/local output. |
| `lua/plugins/ai.lua`, `lua/maxa/provider_config.lua` | Provider-owned LLM/media declarations, independent media-name registration and capability/provider connection defaults. |
| `abilities/genai/` | Media prompts, public tool routing, preflight, visual-review standard and adapter/model override discipline. |
| [[specs/runtime/image-analysis|Image Analysis 运行时规格]] | Public `analyze`, deterministic preparation, hidden child, final-text completion, budget, cancellation and cleanup. |
| [[specs/runtime/openai-responses-adapter|OpenAI Responses Chat Adapter 规格]] | Official Chat/LLM Responses requests, tools, reasoning, parsing and errors. |

Excluded: upstream account availability, pricing, moderation internals, visual-quality guarantees, GenAI model-discovery tool, audio transcription, video editing/remix/list/delete, and aliases for removed service-selection or size controls.

## Stable Public Surface

### Requirement: `genai` registers exactly four media tools

The Native MCP server SHALL register exactly:

| Tool | Required inputs |
| --- | --- |
| `image_generate`, `video_generate` | Nonblank `prompt`. |
| `image_edit` | Nonblank `prompt`, at least one `image_paths` entry. |
| `audio_speech` | Nonblank `input`. |

For every tool, optional `nil`, `vim.NIL`, JSON null and blank strings SHALL normalize to absence without erasing lower-precedence defaults. Unknown adapter, missing per-medium default, undeclared capability, invalid mode/field, or missing API root/credential SHALL fail before network dispatch. Missing/invalid images, masks, references, output directories or media payloads SHALL NOT succeed.

GenAI SHALL expose no model-specific Replicate matte tool, forwarding alias or dedicated prediction orchestration. Generic Replicate operations remain independently owned and unchanged.

### Requirement: Results contain bounded local-file facts

Successful media results SHALL contain selected adapter/model, request metadata, local path, bytes, known format/MIME and bounded warnings; never API keys/credentials (including bearer tokens), base64/binary content, full/unbounded remote logs or broad workflow tutorials. Error bodies SHALL NOT become valid binary artifacts.

Long-running network work SHALL use async jobs/timers and one terminal callback. Timeout/cancellation SHALL stop owned future work where supported and win at most one callback. Synchronous helpers MAY build requests or support deterministic tests, but SHALL NOT block Neovim with polling sleep loops. Safety/moderation and service failures authorize neither infinite retries nor bypasses.

## Adapter Capability Model

### Requirement: Adapters are the only media service identities

GenAI tools, picker, results and persisted defaults SHALL use independent media adapter names as the only service identities: no provider selector/parameter, separate provider registry/persistence or capability `enabled` state. A name equal to a provider ID or LLM name establishes no LLM dependency.

- **Declarations**: `maxa.providers` MAY declare one block each for `genai.image`, `genai.tts`, `genai.video`. Optional nonblank `adapter` names the media service; omission uses the owning provider ID, regardless of LLM presence, names or protocol count. Explicit existing names remain valid without renaming persisted selections. A provider MAY reuse names across LLM/media blocks; different providers SHALL NOT claim the same name. Absent capability means unsupported; protocol, URL, credentials, model, type, endpoint shape or a non-provider registry entry does not establish support. Resolving a direct/built-in adapter SHALL NOT enable an undeclared name.
- **Composition and isolation**: Without network access, provider composition SHALL validate/deep-copy declared capabilities and register lightweight media-name metadata without constructing LLM adapters or discovering models. GenAI SHALL NOT read same-name LLM connection settings or publish derived capabilities through `adapter.maxa.genai`. Media-only services need no LLM declaration. Resolution, registry reads and request merges SHALL return fresh copies so calls cannot mutate shared configuration.
- **Credentials and endpoints**: Root precedence SHALL be capability `base_url` → provider `base_url`; key precedence SHALL be capability `api_key` → provider `api_key`. Same-name LLM overrides SHALL NOT affect media. Deployments using those old overrides must declare them in the media capability. Relative endpoints SHALL join the root exactly once; roots SHALL NOT be inferred from Chat response URLs.
- **Proxy**: Every outgoing media operation, including follow-ups, polling and downloads, SHALL reevaluate the owning provider proxy policy under `.maxa/specs/runtime/plugin-entrypoints.md`; selection SHALL NOT cache proxy values.

### Requirement: Defaults are independent by medium

`maxa.defaults.image/tts/video` each accept a named matching-type preset or inline configuration; GenAI retains one global output directory. Legacy `genai.defaults/default_adapters` remain compatibility inputs only when the new role is absent. Project adapter selections SHALL use existing `_meta.yaml` under [Runtime defaults](../../../runtime/plugin-entrypoints.md); no project model/output/voice/duration overrides are added.

All four public schemas SHALL expose optional `preset`, neither expose nor read `provider`, and label results `Adapter`, not `Provider`. Legacy `adapter` selection remains handler-compatible but is not advertised; conflicting explicit preset/adapter selections fail. Selection and value precedence:

| Selection | Order / boundary |
| --- | --- |
| Adapter | Explicit named `preset` > legacy explicit `adapter` > exact caller Chat's medium override > explicit caller project's medium override > global persisted/role default. Without exact Chat use supplied request/Hub-panel project provenance; without explicit project identity retain global behavior. Never infer project from active buffer/cwd/last Chat. Unsupported/unavailable selected capability fails without fallback. |
| Session override | SHALL survive history restoration/compression; clearing removes only the medium's session override and exposes project/global inheritance. Image override covers generation and editing. |
| Project override | Independent per medium; omission/clear means dynamic global inheritance. Reads/selection affect only that normalized project and do not mutate singleton globals or another project's session. Subsequent requests resolve current project defaults. |
| Ordinary model/parameter value | Explicit tool field > explicit named preset > capability defaults > global media role parameters. Mode, credentials, relative endpoints, wire fields, polling policy and safety limits remain capability-owned; connection precedence is unchanged. |

Shared media roles select no adapter. Current deployment keeps `xuanjing_openai` for image/TTS/video defaults but declares only image; persisted choices still win before deployment. When all choices are absent report no adapter configured; unsupported selected service reports unsupported. Selections neither infer capability nor guarantee account models.

Runtime picker/keymap, project state shape and conservative/global persistence belong to the runtime plugin-entrypoint specification. Existing session/history/compaction guarantees remain; no paid generation is required to validate selection precedence.

## Common Image Contract

### Requirement: Image tools expose request-only size intent

`image_generate` and `image_edit` SHALL accept optional top-level `requested_size = auto | positive-integer WIDTHxHEIGHT` (default `auto`), passed unchanged as upstream `size` only at the selected protocol boundary. Public/`extra` `size`, `aspect`, `ratio`, and `extra.requested_size` SHALL fail locally before dispatch. No fixed size matrix, ratio alias/inference, local support allowlist, aspect-derived instruction, prompt suffix, silent remapping, crop, pad or resize is permitted.

Natural-language canvas/orientation/ratio/pixel requests remain valid prompt content; accepted `requested_size` does not establish output dimensions.

### Requirement: Saved image files are authoritative

Every saved PNG/JPEG/WebP SHALL undergo byte-based signature/dimension inspection independent of optional ImageMagick. Report `actual_format`, `actual_width`, `actual_height`, `actual_size`, bytes, local path, and per-file/aggregate `size_check`:

| Condition | `size_check` / consequence |
| --- | --- |
| Explicit request matches inspected dimensions | `matched`. |
| Explicit request differs | `mismatched`; preserve usable file, visibly warn, never auto-resize. |
| Request is `auto` | `not_applicable`. |
| Metadata unreadable | `unverified`; preserve path, forbid exact-size claims and block exact-canvas completion. |

Exact-canvas completion SHALL depend on actual files, not request values. Result intent SHALL be labeled `Requested size`, never `Size`.

### Requirement: Image calls use selected adapter capability mode

The selected independent media service's `image.mode` SHALL be `codex` or `compatible`; missing/invalid capability SHALL fail locally naming the adapter and allowed values. No public tool-level mode override exists. Agents SHALL omit `preset`, `model`, `text_model` unless requested or explicit selection is task-required, preserving configured defaults. Neither mode depends on a Chat/LLM adapter.

## Codex Responses Image Mode

### Requirement: Codex mode sends a server-side `image_generation` tool request

The selected adapter's Responses endpoint SHALL receive:

| Field / part | Contract |
| --- | --- |
| Outer `body.model` | `text_model`, default `gpt-5.5`. |
| One required `image_generation` tool | `model` default `gpt-image-2.5`; action `generate` or `edit`; `size = requested_size`; `quality="auto"`; fixed moderation behavior; configured output format. |
| Request policy | `stream=true`, `store=false`, `reasoning={effort="none"}`, `tool_choice={type="image_generation"}`. |
| Prompt | `input_text` is the user's prompt verbatim; top-level instructions only for optional prompt-rewrite prevention. No machine-derived aspect requirement. |
| `partial_images` | Default `0` for explicit `WIDTHxHEIGHT`, `1` for `auto`; a valid explicit adapter-capability extension value overrides this. |

Only one final image per call is supported: `n > 1` SHALL fail; multiple candidates require independent calls.

### Requirement: Codex edits use local data URLs

Every local edit image and optional mask SHALL be validated and converted to a data URL: images become ordered `input_image` parts, mask becomes `input_image_mask.image_url`. `detail` SHALL accept `low|high|original|auto`, default `original`, only at its maintained canonical locations.

Stream parsing SHALL ignore partial previews and save only final `image_generation_call.result`, `b64_json`, or URL results. Base64 SHALL decode to a unique local file; URLs SHALL be downloaded and verified nonempty. A response without a final image SHALL fail with `Responses image_generation returned no image result`, adding bounded tool/text hints when available.

### Requirement: Codex retries only transient single-call failures

Configured bounded retries MAY cover retryable transport, timeout, rate-limit, busy-account, overload, stream interruption, selected 5xx/gateway statuses and transient no-final-image results. Authentication, permission, invalid parameter, unsupported model and safety/moderation failures SHALL be fatal. Report retry facts only when retries occurred.

A stream-reset diagnostic MAY suggest likely safety/moderation interruption or gateway failure and a neutral prompt/source; it SHALL NOT claim definite moderation without evidence or loop indefinitely.

## Compatible Images Mode

### Requirement: Compatible mode uses Images API semantics

Compatible mode SHALL send JSON `POST /images/generations` or multipart `POST /images/edits`, non-streaming by default, with present/defaulted fields only. Configured repeated image/mask fields default to `image`/`mask`; `requested_size` maps to upstream `size`; configured `max_n` defaults to `15`.

Ordinary fields include model, prompt, count, requested size, quality, background, response/output format, image references and mask. `text_model` and `extra.text_model` SHALL be rejected: Images APIs have no outer Responses host model.

Responses MAY be official `data`, compatible `images`/`results`, direct objects or bounded `{code,data,msg,message,error}` envelopes. Successful URL/base64 items SHALL be saved locally and summarized without embedded content; nonzero/error envelopes SHALL fail with bounded upstream-service text. Infinite Canvas-compatible request needs are preserved, not byte-for-byte compatibility with every client/vendor endpoint.

## Audio Speech

### Requirement: `audio_speech` produces one local audio file

Beyond required `input`, optional fields are `preset`, `model`, `voice`, `response_format` (`mp3|opus|aac|flac|wav|pcm`), `speed` (`0.25..4`), `instructions`, `output_dir`, `filename_prefix` (default `audio_speech`) and allowlisted `extra`.

The tool SHALL resolve an explicit TTS capability, merge defaults, send JSON to its speech endpoint (default `/audio/speech`), validate ordinary binary audio and save one unique format-appropriate local file. Return adapter/model/voice/requested format/actual MIME/bytes/path. JSON, HTML and text errors SHALL NOT be saved as audio even on nominal success. Streaming/SSE speech is excluded.

## Video Generation

### Requirement: `video_generate` owns the complete asynchronous operation

Beyond required `prompt`, optional fields are `reference_image_paths` (default maximum `7`), `preset` (named Maxa video configuration), `model`, `seconds` (integer `1..20`), `size` (`auto` or positive-integer `WIDTHxHEIGHT`), `resolution_name`, `generation_preset` (upstream generation mode), `output_dir`, `filename_prefix` (default `video_generate`), `timeout_seconds` and allowlisted `extra`. Public `preset` has one meaning; do not guess legacy upstream mode from its value.

The tool SHALL execute this sequence:

1. Validate prompt, model/defaults, duration, size, references and configured limits.
2. Submit multipart `POST /videos` with configured repeated reference field, default `input_reference[]`; map `generation_preset` to upstream `preset`.
3. Parse a direct final URL or compatible task/envelope with an ID.
4. Poll `/videos/{id}` asynchronously until success, failure, cancellation, timeout or configured attempt limit.
5. Prefer a usable result URL; otherwise download `/videos/{id}/content`.
6. Reject empty/API-error content.
7. Return terminal task and local-file facts, never binary content.

Polling defaults to 2500 ms and 120 attempts unless capability policy overrides it; `failed`/`cancelled` are terminal failures. The common one-callback rule applies; caller/runtime cancellation stops future polls and owned downloads where supported. This is the verified Infinite Canvas-compatible video shape, without a public OpenAI/Infinite Canvas mode selector.

## Image Analysis Use By GenAI

Production or high-risk outputs involving text, layout, UI, logos, charts, reference fidelity, multi-panel structure, exact geometry or asset delivery SHALL be reviewed with [[specs/runtime/image-analysis|`analyze`]]. Typical bounded review uses `images[1].target_long_edge=760` with `downscale_only`; native-dimension inspection omits `target_long_edge`.

GenAI receives final analysis text and ordered preparation facts, not ownership of child state or TTL. The removed public `load_image` attachment workflow is excluded.

## Validation Evidence And Remaining Risk

Recorded focused validation covers requested-size schemas/legacy-field rejection, PNG/JPEG/WebP metadata, codex/compatible request construction, capability/default precedence, lazy registry, local TTS/video HTTP fixtures, full Native restart/reload and no-cost local failure smokes. The current four-tool registration is verified through fresh runtime catalog loading. Media composition checks SHALL distinguish omitted/explicit names, media-only and multiple-LLM providers, invalid/colliding names and capability/provider connections despite same-name LLM overrides; fresh runtime resolution and actual picker visibility SHALL preserve existing selections.

The user's 2026-09-15 human specification review passed; it does not establish execution evidence for these remaining boundaries:

- Paid/live upstream TTS/video account/model availability was not run; adapter/model availability remains deployment-specific.
- Third-party compatible APIs may drift.

Chat/LLM Responses behavior is owned by [[specs/runtime/openai-responses-adapter|OpenAI Responses Chat Adapter 规格]], not this media contract.

## Source Trace

The [ownership table](#scope-and-ownership) identifies Native dispatch, adapter declarations/defaults and analysis/Chat protocol owners. Detailed implementation/contract paths:

| Area | Sources |
| --- | --- |
| Image drivers | `lua/maxa/mcphub/native_servers/genai/image/providers/openai_responses_image_generation.lua`, `openai_compatible.lua`. |
| Audio/video drivers and tools | `lua/maxa/mcphub/native_servers/genai/audio/`, `video/`, `media/`, `tools/`. |
| Media/visual-review contract | `abilities/genai/SKILL.md`, `abilities/genai/SYSTEM.md`, `abilities/genai/references/`. |
