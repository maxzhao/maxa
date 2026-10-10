# Scientific Figure

Use for research figures, method figures, pipeline diagrams, cohort flows, benchmark charts, conference posters, and labeled architecture diagrams. Inspired by scientific figure workflows; keep structure and constraints only, not copied prompts.

## Use Cases

- Paper method figure, system pipeline, model architecture diagram.
- Cohort flow, experiment flow, sample selection.
- Benchmark chart, small multiples, experimental comparison.
- Single visual module or full-page concept sketch for a conference poster.
- Style target from sketch/PDF/text spec before draw.io / SVG / PPT refinement.

Shared image generation/editing techniques are owned by `references/craft.md`; the schema and example below are optional domain briefs. Use `references/preflight.md` for runtime-dependent request settings and exact-size handling, separately from visual prompt text.

## Mini Schema

```text
Create a scientific figure sketch for [paper/topic].
Figure type: [pipeline diagram / method figure / cohort flow / benchmark chart / architecture diagram / poster panel].
Canvas: [landscape/square/poster], white background, publication-style margins.
Layout: [left-to-right / top-down / grid / multi-panel A-B-C].
Modules: [exact module names and short labels].
Connections: [arrows, data flow, feedback loop, grouping].
Data/labels: [axis labels, legend, units, cohort counts if any].
Style: [journal figure / clean vector / conference poster / draw.io-ready].
Constraints: preserve all supplied modules, connections, labels, values, and units; legible labels, no random formulas or unsupported claims, editable-figure mindset.
```

## Required Controls

- Figure type: pipeline, method figure, cohort flow, benchmark chart, architecture diagram, or poster panel.
- Modules and labels: every box, arrow, axis label, legend, unit.
- Reading order: left-to-right, top-down, panel A/B/C, layered, or swimlane.
- Scientific semantics: input, processing, output, experimental/control group, metrics, sample size.
- Post-processing strategy: generated raster output is a reference/workflow sketch/style target; final publication figure should be refined in draw.io / SVG / PPT.

## Recommended Sizes

- Landscape method figure: `2048x1152`.
- Square architecture/concept: `1024x1024` or `2048x2048`.
- High-detail technical diagram: `2048x1152` or `3840x2160`.
- Conference poster sketch or portrait module: `1024x1536` or `2160x3840`.
- Simple chart/flow sketch: `1536x1024`.

## Pitfalls

- Do not let the model invent formulas, pseudocode, citations, or unreadable microtext.
- For complex diagrams, enumerate required modules, source-to-target connections, and exact labels. Repair layout or text rendering without deleting scientific content; use `references/preflight.md` for supported quality and resolution options.
- For paper/submission use, state it is a sketch/style target, not final publication vector art.
- Values, units, legends must come from the user; use placeholders instead of invented results.
- Prefer white background, clear arrows, editable-vector feel; avoid tech illustration overpowering semantics.

## Visual Verification

- Check every module name, axis label, legend, unit, sample count, and panel marker.
- Check arrow direction, data flow, grouping, and reading order.
- Check for random formulas, pseudocode, fake citations, unprovided data, or unreadable microtext.
- For paper use, confirm final reply states reference/workflow sketch/style target, not final publication vector.

## Prompt Skeleton

```text
Create a landscape scientific method figure sketch for a paper about retrieval-augmented clinical note summarization.
Figure type: left-to-right pipeline diagram on a white background with publication-style margins.
Layout: four numbered stages with clear arrows: (1) "Clinical Notes", (2) "De-identification", (3) "Retriever + Evidence Store", (4) "Summarization Model", ending at "Audited Summary".
Add a small legend strip at the bottom: "blue = input data", "green = retrieval evidence", "orange = generated output".
Use clean vector blocks, thin arrows, readable labels, restrained scientific colors, and draw.io-ready geometry. Preserve every listed stage, connection, and legend label. Avoid random formulas, fake citations, unlabeled arrows, and invented performance numbers.
```
