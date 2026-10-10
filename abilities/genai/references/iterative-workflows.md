# Iterative Editing and Candidate Branch Workflows

Purpose: keep `@genai:image_edit` iterations anchored to one evolving image. Previous output becomes next input; passed visual elements become invariants; only explicit failures are repaired. Review every round with `references/image-edit-review-standard.md`: allow normal generative redraw when protected content retains first-glance identity and the requested change succeeds; do not require 1:1 pixels or exact seams unless a named technical invariant requires them.

Apply `craft.md` before writing follow-ups and `preflight.md` for request settings. These session-state and cost rules are Maxa orchestration, not additional model syntax requirements.

## Use / Avoid

Use iterative workflow for:

- Reference repair: result is close, but text, Logo, local layout, details, or composition need fixes.
- Style micro-adjustment: keep subject/composition; change color, material, lighting, medium, era.
- Brand consistency: iterate palette, logo placement, typography, touchpoints around one brand asset.
- Text repair: quote the required copy and clarify placement, typography and repetition without remaking the whole image or silently shortening user text.
- Composition refinement: adjust position, whitespace, gaze, module hierarchy, reading order.
- Draft-to-final: start with rough base, then improve clarity/material/brand/delivery quality.

If the direction is fundamentally wrong, establish a new baseline. A new scene can still use a reusable character/product reference through `image_edit`; use `image_generate` when no image reference is needed.

## Loop

1. Generate/edit first image and capture output path.
2. Verify with `references/image-edit-review-standard.md` by calling `analyze(images={{path=..., target_long_edge=760}}, analysis_prompt="Review the complete image for requested-change success and first-glance identity; report path, evidence-based pass items, issues, uncertainty, and the next prompt change.", max_steps=1)`; use a separate explicit crop analysis with `region={x,y,w,h}` for small text/Logo/UI/local fidelity. Complete-view first-glance identity is primary evidence; crops and overlays are secondary unless a strict technical exception applies.
3. Use the returned report directly as the round record. Do not duplicate it with parent `report` or manage image TTL.
4. Next round uses the selected previous output in `image_paths`. Add a reusable identity/style reference only when it contributes necessary information; label every input's role.
5. Request one focused change and restate critical preservation constraints. A short prompt is sufficient for a simple follow-up; use labeled sections for interacting requirements. Repeat any output-setting requirement owned by the caller and recheck the returned file facts.
6. Inspect each result before adding instructions. Repeated edits can drift; pixel-identical protected regions require deterministic compositing into the original, followed by verification.
7. Default automatic repair limit: 1 extra generation/edit; more rounds require user confirmation or explicit authorization under `media-calls.md`. This is a local cost boundary, not an OpenAI model rule.

Example call shape:

```json
{
  "prompt": "Image 1 is the poster to edit. Replace only its headline with 'SUMMER SALE', appearing once in the existing headline area with readable typography. Preserve the product shape, package label, camera angle, warm lighting, background gradient, logo placement, CTA button and overall layout. Add no other text or logos.",
  "image_paths": ["/absolute/path/to/round-1.png"],
  "requested_size": "auto",
  "output_format": "png"
}
```

## Edit Session Prompt Schema

Optional scaffold for complex edits; render visible roles rather than internal approval/round/branch codes:

```text
Previous image role:
- Image 1 is the [poster / portrait / product photograph] to edit; other inputs supply [specific reference role].
- Treat it as source of truth for [composition / identity / brand / style / layout].

Change request:
- Change only [specific failure or requested improvement].
- Specify target area, exact text, region, style, or layout adjustment.

Preserve invariants:
- Preserve [subject identity, face/hair/clothes, product geometry, logo, palette, typography, camera angle, layout, panel count, background relationship].
- Keep all passed elements unchanged.

Do not change:
- Do not alter [approved elements].
- Do not invent extra text, fake sponsor logos, new products, new characters, or new panels unless requested.

Quality constraints:
- readable text, stable geometry, crisp UI/diagram labels, no identity drift, no garbled characters, no extra artifacts.
```

## Candidate Branch Workflow

Use for open aesthetic tasks: poster direction, brand visual direction, character design, product hero, UI landing hero.

1. Write 2-3 distinct prompt directions:
   - Direction A: safe production, clear layout, brand consistency.
   - Direction B: stronger style/medium/light/mood.
   - Direction C: commercial conversion, product/CTA/hierarchy.
2. Default to one candidate per call or prompt option. Use an explicit `n` only when the configured adapter supports the requested count; follow `preflight.md`.
3. Independent candidates can use titled `multicall(mode="parallel")` with tool-mode `runs` members and encoded object `args`; no member `label` exists. Apply the concurrency/cost limits in `media-calls.md` and associate each separate member output with its input candidate. Selected-branch edits must be separate sequential invocations because `image_paths` depends on the selected output; a fixed sequence batch cannot substitute target-result references.
4. After selection, use the selected output as the edit source. Describe its visible role in the prompt, not its internal branch label.
5. Do not keep loading all historical images; retain paths + short observations, reload only relevant current candidates.

Candidate record:

```text
Candidate A
- prompt: ...
- output: /path/to/a.png
- verification: strong brand consistency, weak headline readability

Selected: Candidate B
Next edit source: /path/to/b.png
Repair focus: restore logo geometry and improve CTA readability
```

## Failure Repair Playbook

- **Text wrong/garbled/extra**: preserve required copy; quote exact strings, clarify typography/placement/occurrence count, and separate text regions. Compare a supported medium/high setting when small text is the issue; do not silently remove words.
- **Layout/module count wrong**: preserve required modules; specify regions, exact panel count, relationships and reading order. Propose a different layout or deterministic composition if generation cannot meet the full contract.
- **Identity drift**: strengthen face, hair, clothes, body geometry, silhouette, camera angle, product shape; declare previous output as source of truth.
- **Brand drift**: strengthen palette, logo geometry/placement, typography, package label, touchpoints; forbid fake sponsors/extra brands.
- **Style mismatch**: use concrete medium, era, design context, camera/material/light; avoid vague beautiful/modern/premium.
- **Local edit damages whole image**: narrow to one area and name protected surroundings, saturation, contrast, labels and arrows where relevant. Use a provided local mask only through supported transport. For pixel-identical surroundings, composite the approved local edit into the original; do not silently change adapters or claim repeated prompting guarantees preservation.

## Artifact Trace

Record enough to continue without re-exploring:

```text
Round: 2
Mode: image_edit
Input paths: [/absolute/path/to/round-1.png]
Prompt summary: fix headline text, preserve product and layout
Output path: /absolute/path/to/round-2.png
Visual verification:
- pass: product geometry, warm lighting, logo placement
- issues: CTA text still slightly blurred
Decision: stop / repair once / ask user to choose next direction
```

Principles: previous output path must enter next `image_paths`; the analysis report’s pass/issues become invariants/change request; default auto-repair limit is 1.

## Manual Example

User: “Use this image as the base, change the title to a short exact headline, and keep the current composition and color tone.”

1. Identify previous output path, e.g. `/tmp/genai/round-1.png`.
2. Verify visually: product centered, warm gradient, logo passed; title is English.
3. Next edit prompt:

```text
Image 1 is the product poster to edit.
Change request: replace the headline with exact text: “SUMMER REFRESH”. Keep it in the same top-right headline area with readable, bold typography.
Preserve invariants: keep the same product, central composition, warm orange gradient background, logo position, lighting, package geometry, and overall poster layout.
Do not change: product shape, logo, CTA position, color palette, camera angle, background style, or any already-correct visual elements.
Quality constraints: readable typography, no garbled text, no random extra copy, no extra logos.
```

4. Call `@genai:image_edit` with `image_paths: ["/tmp/genai/round-1.png"]`.
5. Verify `/tmp/genai/round-2.png`; if still wrong, repair at most once more by default.
