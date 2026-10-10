# Image Settings And GenAI Preflight

Purpose: separate image-generation capabilities from the GenAI transport contract before `@genai:image_generate` / `@genai:image_edit`. Shared prompt-writing authority is `craft.md`.

Source: [OpenAI Image prompting](https://developers.openai.com/api/docs/guides/image-prompting), verified 2026-09-10. This handbook extracts common prompting and setting principles; it does not select a model or prescribe model-specific workflows. API support remains subject to the configured runtime.

## Settings Separate From The Prompt

| Setting | Guidance |
| --- | --- |
| Quality | Omit for configured defaults. Supported quality levels may include `auto`, `low`, `medium`, `high`, `xhigh`, `max`; do not assume every transport supports them. Compare medium/high for small text, dense labels, figures, axes and legends when supported. Higher settings are useful only if they improve an unmet requirement within the latency/cost budget; higher is not always better. |
| Size | Omit or use `auto` when unspecified. Common recommendation sizes: `1024x1024`, `1536x1024`, `1024x1536`, `2048x2048`, `2048x1152`, `3840x2160`, `2160x3840`. Choose for the actual composition and delivery need, subject to runtime support. |
| Background | Omit for configured defaults. Pass an explicit supported value only when required by the current caller; a rejecting transport needs a supported path, not different adjectives. |
| Compression | Only for JPEG/WebP when the adapter documents support; omit for PNG. Compression is not image quality. |

The cited guide's custom-resolution envelope is a planning reference, not a universal parser rule or guarantee for every configured backend:

- Each edge is at most 3,840 pixels and a multiple of 16.
- Long edge / short edge is at most 3:1.
- Total pixels are between 655,360 and 8,294,400 inclusive.
- Outputs above 3,686,400 pixels (`2560x1440`) are experimental in the cited guide. Scope high-resolution cost and latency; do not promise better output from more pixels.

Historical observed saved dimensions are not recommendations for new requests. Recheck current capability documentation when the configured runtime or requested setting changes.

## GenAI Mapping And Runtime Boundaries

Use configured defaults without inspecting or reporting adapter identity during successful ordinary work. Omit `preset`, `model`, and `text_model` unless the user requests an override or the task needs an explicit named configuration. `preset` selects a matching image/tts/video entry from `maxa.presets`; omission preserves session/project/global defaults. This guidance does not migrate the backend.

| Concept | Public GenAI mapping / handling |
| --- | --- |
| Prompt | `prompt`: model-visible visual requirements only; no request metadata or Agent-only state. |
| Generate / edit | `image_generate` without references; `image_edit` with readable local absolute `image_paths`. Label input roles by number. |
| Size | `requested_size`. No top-level or `extra` `size`, `aspect`, `ratio`, or `extra.requested_size`. Express visual composition/aspect ratio in the prompt separately. |
| Quality | Public `quality` field, subject to the configured driver. Omit for defaults. Do not move a rejected API setting into prose and call it equivalent. |
| Background | Public `background` field; omit unless the current request or calling workflow requires an explicit value. |
| Format | `output_format`: `png`, `jpeg`, `webp`. |
| Reference detail | `detail="original"` for fidelity-sensitive reference input on supported adapters; it is not a preservation guarantee or permission to add unrelated upstream fidelity fields. |
| Mask | `mask_path` only when the user explicitly provides a local mask for localized editing. Keep target/preserve instructions even with a mask. A specialized workflow may have its own explicitly scoped deterministic-mask contract; that does not change the ordinary entry condition. |
| Variations | Default to separate calls. An explicit `n` requires the configured adapter's count support; one-image transports must use separate requests. |
| Returned data | Omit `response_format`; GenAI saves local files and returns facts, never image base64 in chat. |
| Other settings | Use `extra` only for a documented, currently supported extension. Do not copy speculative fidelity, metadata, compression or API fields from another transport. |

### Local Compatibility Limits

The current local Responses image driver fixes quality to `auto`, supports one image per call, and rejects fixed request metadata overrides such as `tool_choice`, `reasoning`, `store`, and `instructions`. These are **local driver restrictions**, not universal image-generation limits. Other configured adapters may have different contracts.

Do not silently switch adapters or patch the runtime after a rejected capability. Preserve the diagnostic, use a supported user-authorized path, or explain the required runtime update. Do not spend repeated calls on the same unsupported parameter. Adapter development is a separate route.

## Size And Default Calls

When unspecified, omit size or use `requested_size="auto"`. Use a concrete recommendation only when it helps the deliverable and is supported. Templates are suggestions, not user-size overrides.

Preserve an explicit user `WIDTHxHEIGHT` unchanged. If it conflicts with documented backend support, explain the incompatibility before calling; do not silently round, remap, crop, pad or rescale. GenAI accepts positive-integer size syntax more broadly than some backends. A calling workflow may impose stricter source-canvas requirements.

Minimal calls, with configured defaults:

```json
{"prompt":"<self-contained visual request>","requested_size":"auto","output_format":"png"}
```

```json
{"prompt":"<change and preservation request>","image_paths":["/absolute/path/to/input.png"],"requested_size":"auto","output_format":"png"}
```

After every successful file inspect `actual_size`, `actual_format`, and `size_check`. Exact-canvas delivery requires `size_check=matched` or equivalent deterministic dimension evidence; the request alone is not proof. A calling workflow may impose additional checks.

## Prompt And Template Preflight

- Read `craft.md`; preserve user specificity, text, data and requested content. Format is optional, applicable controls are not.
- Separate visual brief from request parameters. Render useful template fields; omit empty placeholders, internal YAML metadata and Agent-only jargon. Do not fabricate missing brand, UI, research, or business facts.
- Identify reference roles, edit targets, changes, protected regions and named invariants. An exact-pixel contract needs deterministic compositing and validation, not stronger wording alone.
- Respect local mask/candidate/runtime constraints; keep explicit user requirements visible when a capability is rejected.
- Plan visual verification for text, layout, reference fidelity and production outputs. Scope batch/high-resolution costs; independent calls can start with `max_concurrency=2` under `media-calls.md`.

## Controlled Setting Comparisons

When tuning is requested, keep representative prompts, references, dimensions and format unchanged for the initial comparison. Change one setting at a time; compare supported quality levels before rewriting an otherwise adequate prompt. The same setting label across backends does not imply equal quality or latency.

Check instruction following, identity/product preservation, text, dimensions, format, and unintended edits. Test complete edit sequences as well as single steps; repeat representative requests within the authorized budget when consistency matters. Measure typical/slow responses, failures, retries and cost per accepted image using current pricing. Retain the accepted baseline for rollback; do not infer fixed speed gains or cheaper accepted output from a setting name or one example.
