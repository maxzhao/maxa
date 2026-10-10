# Reference Image Editing

Use for `@genai:image_edit`: reference edits, redraws, style transfer, multi-reference fusion, variants from an existing image, and continuing from previous output. Supply readable local references through `image_paths`; consult `references/preflight.md` for optional mask support. With or without a mask, the prompt must define edit scope and invariants.

Shared image generation/editing techniques are owned by `references/craft.md`; the schemas below are optional domain briefs. Use `references/preflight.md` for runtime-dependent request settings and exact-size handling, separately from visual prompt text.

## Mini Schema

```text
Edit the reference image; change only [target change].
Preserve [main subject identity / layout / geometry / text / brand / camera angle].
Keep [specific invariants] unchanged.
Apply [new style/material/lighting/context] to [target elements].
If multiple references:
Image 1: [role]
Image 2: [role]
Image 3: [role]
Combine them by [relationship].
Constraints: preserve composition, avoid identity drift, keep original readable text unless replacement is requested.
```

## Review Contract

After every edit, apply `references/image-edit-review-standard.md`. Treat the output as generative rerendering: verify that the requested change succeeded and protected content still reads at first glance as the same subject/design. Accept normal differences in antialiasing, texture, highlights, gradients, micro-contours, and other low-salience details. Do not require 1:1 pixels or exact overlay/split seams unless the user or a downstream computation explicitly names a strict invariant; scope strictness to that invariant only. If a region must remain pixel-identical, composite the approved edit into the original deterministically; a prompt or mask is not a pixel-preservation guarantee.

## Required Controls

- Intent: edit an existing image, generate from references, style transfer, compositing, or previous-output continuation.
- Change request: what changes.
- Invariants: relevant identity, geometry, labels, layout, camera angle, lighting, saturation, contrast, arrows, and surrounding objects that must remain; do not protect a property the requested edit is meant to change.
- Reference roles: define each image in order for multi-image edits; do not assume every input image is an edit target.
- Style source: text description or specific reference image.
- Text policy: preserve, translate, replace, or remove.
- Compositing relation: what moves where, scale, perspective, lighting, shadows, and protected base framing.

## genai Params

```json
{
  "prompt": "...",
  "image_paths": ["/absolute/path/to/input.png"],
  "requested_size": "auto",
  "output_format": "png"
}
```

Resolve supported `quality`, masks, output format, and candidate-count settings through `references/preflight.md`; these depend on the configured runtime rather than prompt wording.

For a user-provided local mask, follow `references/preflight.md`. If the transport rejects it, retain the diagnostic and preservation requirements; use only a supported authorized path. A safety rejection is not a reason to switch providers or remove constraints to bypass it.

## Continuous Editing

When the user says “continue”, “tune again”, or “use this as the base”, use previous output as the new reference instead of regenerating from scratch. Verify previous output, record pass/issues, then put previous output path in `image_paths`. Passed items become preserve invariants; failed items become change request.

```text
Previous image role: use the input image as the approved base from the previous round.
Change request: [only the specific fix for this round].
Preserve invariants: keep [approved subject / layout / brand / text / lighting / style] unchanged.
Do not change: [elements that already passed visual verification].
Quality constraints: readable text, stable geometry, no identity drift, no extra random text.
```

Follow `references/media-calls.md` and `references/iterative-workflows.md` for repair authorization and cost boundaries. Load only the current comparison target rather than all historical images, and summarize observations in text.

## Candidate Branches

Open-ended tasks may start with 2-3 prompt directions or separate candidate calls. Generate one candidate per call by default; resolve any explicit batch request through `references/preflight.md`. After selection, use the selected output path as next `image_paths` and record it as the `selected candidate branch` outside the visual prompt.

Record candidate prompt, output path, visual verification, selection reason, and next repair focus.

## Pitfalls

- “Change to this style” causes drift unless preserve constraints are explicit.
- Local images can be style/composition/mood references, not only edit targets; state roles explicitly.
- Poster/UI edits preserve original text by default unless user requests replacement.
- Brand/Logo/character identity must be repeated as invariants.
- Multi-reference fusion must define subject, style, logo/texture roles.
- Compositing fails when scale, perspective, lighting, and shadow matching are unspecified.
- `mask_path` helps only when provided and supported; prompt still defines region, change, and protected areas.

## Prompt Skeleton

```text
Transform the reference image into a premium cyberpunk poster while preserving the original main subject, camera angle, and overall composition.
Keep the subject identity, silhouette, and facial structure unchanged. Preserve any original readable text unless it is explicitly replaced.
Apply neon magenta and cyan rim lighting, rainy night reflections, subtle holographic background panels, and cinematic poster contrast.
Constraints: avoid identity drift, keep geometry stable, preserve original layout, no garbled extra text, no fake sponsor logos.
```

## Multi-reference Skeleton

```text
Use the input images as follows:
Image 1: main product photo, preserve product shape and label placement.
Image 2: visual style reference, apply only the lighting and color mood.
Image 3: logo reference, place the logo on the package front.
Create a polished ecommerce hero image. Preserve Image 1 product geometry and Image 3 logo readability. Do not invent additional logos or change the product silhouette.
```
