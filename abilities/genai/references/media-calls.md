# Media Calls And Acceptance

Purpose: generate/edit images, synthesize speech, or generate video with adapter-neutral public tools. For every image prompt, first apply `craft.md`'s shared prompting contract. Paths below are relative to the `genai` Ability root.

## Inputs And Calls

Use titled `run(scope="tool")` with the appropriate `@genai:image_generate`, `@genai:image_edit`, `@genai:audio_speech`, or `@genai:video_generate` command. Encode the target parameter object as a JSON string in `args`; the objects below are target payloads, not wrapper argument objects. Keep adapter identity out of ordinary successful reports. Omit `preset`, `model`, and `text_model` unless requested or an explicit configuration is task-required. `preset` selects a matching named media configuration; explicit request fields override its values.

Minimal parameters by medium:

```json
{"prompt":"...","requested_size":"auto","output_format":"png"}
```

```json
{"prompt":"...","image_paths":["/absolute/path/to/input.png"],"requested_size":"auto","output_format":"png"}
```

```json
{"input":"..."}
```

```json
{"prompt":"...","reference_image_paths":["/absolute/path/to/reference.png"]}
```

For edits, `image_paths` must be readable local absolute paths; label every image by its visible role in the prompt. Use `detail="original"` for fidelity-sensitive reference edits. Video reference paths are also local absolute paths, at most seven unless the configured adapter reports a lower limit. Prompt-only requests return structured prompts and optional parameter advice without generation calls.

## Parameters And Size

Pass only necessary public fields and check `references/preflight.md`:

- `requested_size`: omit or use `auto` when unspecified; use `preflight.md` for supported recommendations. Preserve an explicit user `WIDTHxHEIGHT`; explain unsupported dimensions rather than silently remapping them.
- Unsupported top-level `size`, `aspect`, and `ratio`: express orientation, canvas, ratio, and composition in prompt language instead.
- `output_format`: `png`, `jpeg`, or `webp`.
- `background`: omit for configured defaults unless the current caller requires an explicit supported value. Treat a local-driver rejection as a transport fact, not a universal model limitation.
- `n`: omit; independent candidates use separate calls.
- `mask_path`: only for an explicit local-mask edit. If rejected, classify the actual error before attempting a no-mask repair.
- `response_format`: omit; outputs are saved locally.
- `quality`: omit for configured defaults; supported quality levels are independent of visual prose. Use `preflight.md` for task-relevant tuning and current transport restrictions; prompt adjectives are not equivalent to an API quality setting.
- `extra`: only documented extensions needed by the current request, not copied fields from another API.
- Speech: `input` required; omit preset/model/voice/format overrides unless needed.
- Video: `prompt` required; `seconds` must be `1..20`; `preset` is a Maxa video configuration name, while `generation_preset` is the upstream generation mode. Omit overrides unless needed.

`preflight.md` is the single owner of model size constraints and public parameter mapping. After each generation/edit inspect saved-file `actual_size`, `actual_format`, and `size_check`; requests and recommendations do not guarantee saved dimensions.

## Independent Calls

Use titled `multicall(mode="parallel")` only when calls are independent; explicitly set `max_concurrency` to `2` initially. Its default `0` starts all members without a cap; do not use unbounded parallelism without user acceptance of cost/rate-limit risk. Put 1–16 requests in `runs`; each member has `scope="tool"`, target `command`, and matching encoded JSON object `args`, with no `label`. Normally omit member `title`. The declaration returns closure facts and each member returns its separate full output; a candidate's execution error is not necessarily total task failure. Atomic preflight rejects invalid/unavailable/interactive/nested members before any dispatch. Do not nest `multicall` or target `run`/`multicall` through tool-mode members.

Parallel candidates may include 2–3 directions, style variants, independent screenshots/logo concepts/storyboards, or size/composition trials. Stay sequential when later calls need earlier output paths, visual acceptance, user selection, masks/references, or preserved accepted state. Provider retries do not govern later independent requests.

## Prompt And Visual Acceptance

Before generation/editing, apply `craft.md`: verify a self-contained prompt with applicable result, composition, subject, visible details, exact text and preservation constraints. Short instructions and structured briefs are equally valid; do not require a fixed order or extra creative detail. Keep API settings separate. Plan visual evidence for high-risk deliverables; use deterministic compositing when protected regions must stay pixel-identical.

After generation/editing, use `analyze(images={{path=..., target_long_edge=760}}, analysis_prompt=..., max_steps=1)` for text accuracy, layout/module counts, brand/Logo/package identity, reference fidelity, fusion, charts/diagrams, storyboards, sprite sheets, App Store screenshots, slides, or other production deliverables. Name the goal, final prompt, required controls, and evidence format. Choose another explicit `target_long_edge` / `resize_mode` or larger bounded `max_steps` only when needed. Use `region={x,y,w,h}` for small text or local detail.

For comparisons, pass all source/candidate images jointly in order and label their roles. Keep combined review/contact sheets when layout, rulers, or annotations are required evidence. Apply `references/image-edit-review-standard.md`; normal redraw is acceptable when first-glance identity and named invariants hold, not blanket pixel/seam equality.

- Judge against the goal and required controls, not aesthetics alone.
- Consume the child's returned `content` directly; no child or parent `report` duplication or image TTL handling is required.
- Do not output base64 image content in chat.
- Candidate paths, passed invariants, concrete issues, and next prompt changes remain available for iterative repair. Severe unresolved issues preclude a completion claim.
- Visual checking may be skipped for low-risk exploration, abstract mood images, or prompt-only work; state the relevant reason for omitted generation/checks.

## Failure And Completion

- Rejected parameters/capabilities: repair from actual errors, not guessed compatibility.
- Safety/moderation/network interruption: classify with `references/safety-and-edit-failures.md`; do not treat moderation as network failure.
- Mask failures: distinguish unreadable file, encoding failure, unsupported `input_image_mask`, and moderation. Use an explicitly capable adapter or no-mask prompt only when appropriate.
- Prompt-fixable failure on a requested final usable asset: automatically make at most one extra generation/edit; further paid rounds require explaining issue/cost/risk and obtaining confirmation. A calling workflow may define a narrower scoped loop policy.
- No image result: possible tool stripping, account-plan or adapter/model mismatch, or parser gap; keep the error summary and try minimal parameters if useful.
- Missing reference: verify readable local paths.

Return deliverable paths, relevant validation, and unresolved requirements. Tool success without required visual or file evidence is not complete delivery.
