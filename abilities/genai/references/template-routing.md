# GenAI Template Routing

Use templates only when they add repeatability, variable control, or production preflight. Every image prompt follows `references/craft.md`'s shared contract; category/template briefs are optional task adaptations, not special syntax or a reason to over-author a simple request.

## Category vs Template

| Scenario | Source |
|---|---|
| One-off prompt/design, vague goal | `references/craft.md` |
| Clear category, non-repeat deliverable | `references/gallery-index.md` + one category |
| App Store screenshot, scientific figure, pitch slide, logo grid, storyboard, game sprite, ecommerce hero | Matching YAML template + category |
| Suite / batch / repeatable / reusable / workflow-style request | this file + YAML template |
| Iterative edit/candidate branch | `references/iterative-workflows.md`, optionally template |
| Adapter capability/parameter compatibility | `references/adapter-development.md` + `references/preflight.md` |

Templates augment craft/category; they do not replace them.

## Selection Steps

1. Extract domain, use case, output, references, batch/candidate needs.
2. Choose one closest template from `references/templates.md`.
3. If none fits, fall back to Markdown category; do not force a template.
4. If multiple templates are needed, split the task order, e.g. brand identity -> ecommerce hero -> app store screenshot; character design -> game sprite frame/sheet.
5. For production work, default to one sample/render first; batch assets become independent calls. Use titled `multicall(mode="parallel")` only when assets are independent, with an explicit concurrency cap under `references/media-calls.md`. Issue separate sequential calls when later assets depend on output, user choice, or verification; fixed sequence batches do not supply result references or dynamic arguments.

## Missing Variables

| Case | Handling |
|---|---|
| Brand name, real UI source, exact text, research data/units/sample size, product claims, reference path | Ask the smallest necessary question before generation |
| Style, background, palette, composition, device frame, sketch level, default size | Infer safely and state the assumption |
| Unknown scientific/business values | Use explicit placeholders; do not invent results/metrics |
| Prompt-only/template-only request | Keep `{{variable}}` placeholders; do not call genai |

If the user says “directly generate” but missing facts would cause wrong content, ask. If only style is missing, proceed with safe defaults.

## Render Method

Render applicable `prompt_schema.structure` fields into a maintainable prompt: a short instruction, descriptive paragraph, or labeled/JSON-like brief. Do not send internal YAML metadata to the image model.

1. Replace `{{variable}}` with user input.
2. For `{{variable | default: '...'}}`, use default or omit.
3. Remove empty fields, internal comments, and YAML field names unless useful in natural language.
4. Convert `provider_constraints.notes` into call plan, e.g. reference image → `image_edit`.
5. Use `visual_verify` after generation, not as a full prompt dump; keep only critical quality constraints in prompt.

The prompt must cover applicable deliverable, composition, subject/content, required exact text/data, visible detail and preservation constraints. Omit irrelevant scaffold fields; do not shorten user copy or add content to fill them. API settings remain separate.

## Preflight Params

Check `references/preflight.md`. Default generate params:

```json
{"prompt":"<rendered prompt>","requested_size":"auto or template recommended_requested_size","output_format":"png"}
```

Use `recommended_requested_size` only when no user size is specified and it satisfies `references/preflight.md`. Preserve an explicit user `WIDTHxHEIGHT`; explain incompatibility before calling rather than silently remapping it. An observed saved dimension is not an official model request recommendation.

For local references, use `image_edit` and add:

```json
{"image_paths":["/absolute/path/to/input.png"]}
```

`references/preflight.md` owns public-field mapping and current transport restrictions. Omit adapter/model overrides unless requested; no public `provider` selector exists. Do not copy upstream `size` into GenAI or use removed `aspect`/`ratio` controls. Omit PNG compression. Verify saved dimensions, format, and visual requirements independently of call success.

## Plan Before Calling

Output a plan instead of calling when: suite/deck/batch/candidates lack a first target; key facts are missing; 4K/high-res or many calls may be costly; user asks only for prompt/template/plan; multiple templates need sequencing.

Plan includes: selected template, missing variables, assumed defaults, rendered prompt draft, suggested params, visual verification checklist, and parallel/sequential call plan when relevant.

## Verify and Repair

After generation/edit, call `analyze(images={{path=..., target_long_edge=760}}, analysis_prompt="Check template visual_verify against the target and prompt; report pass/issues/path and uncertainty.", max_steps=1)` and consume its returned report directly. For `image_edit`, also apply `references/image-edit-review-standard.md`: verify the requested change and first-glance perceptual identity of protected content; accept normal redraw and micro-detail drift, and do not require 1:1 pixels or exact seams unless a named technical invariant requires them. If failure is clear and final asset is desired, repair at most once by default using only failure points + preserve invariants. If the configured provider rejects a requested capability, explain the limitation and alternatives.
