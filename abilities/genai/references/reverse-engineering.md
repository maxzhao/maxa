# GenAI Case Reverse Engineering

Purpose: extract reusable genai rules from user-provided images, prompts, links, competitor visuals, or generated results. Use `load(target="genai")`, then `read(path="#genai[/references/craft.md]")` for the shared prompting contract; treat case findings as task-specific heuristics, not model requirements. Keep source facts, inferred controls and untested claims distinct; do not copy source prompts or legacy API settings.

Read the selected references through their cataloged addresses with `read` (or `load`), not filesystem paths. Source/candidate images and project-output files still use concrete local paths. Reference locations listed below identify maintenance destinations, not permission to filesystem-load the Ability.

## Outputs

Turn a good case into:

1. Executable prompt.
2. Reusable schema.
3. Category pitfalls.
4. Small rule patch suitable for `abilities/genai/references/categories/*.md` when broadly reusable.

## Input Handling

| Input | Action |
|---|---|
| Image | Observe visible facts first, then extract structure |
| Prompt | Split into fields and identify effective controls |
| Image + prompt | Compare result vs prompt to find what worked |
| Repo/case set | Read index/classification, then sample only relevant category |
| Failed generation | Identify failure pattern, then rewrite prompt or params |

## Seven-Step Method

1. **Classify**: choose primary and optional secondary category: UI/UX, infographic, poster, product, photography, character, technical/research diagram, reference edit. Mixed cases read at most 2 categories.
2. **Observe facts** before interpretation:

```text
output_type:
canvas/aspect:
layout_regions:
subject:
viewpoint/composition:
text_blocks:
style_anchor:
palette:
lighting/material:
information_hierarchy:
quality_markers:
```

3. **Extract controls**: canvas, layout, subject, style, exact text, material/light/camera, constraints.
4. **Write a maintainable brief**; the following schema is optional, not special model syntax:

```text
Create a [output_type] using this structured brief:
{
  "canvas": "...",
  "layout": "...",
  "subject": "...",
  "content": {"exact_text": ["..."], "labels": ["..."]},
  "style": {"anchor": "...", "palette": "...", "lighting_or_material": "..."},
  "constraints": ["..."]
}
```

5. **Extract pitfalls** and state what failure they prevent: generic UI, chaotic infographic, Chinese garbling, subject drift, invented data/logo, etc.
6. **Separate visual controls from settings**: use `read(path="#genai[/references/preflight.md]")` to translate request parameters; distinguish general guidance from local-driver restrictions. Use `requested_size` and verify saved dimensions and format. Quality prose does not replace a supported API quality setting.
7. **Choose landing location**.

## Image Review Lifecycle

For a source-image reverse-engineering loop, use `read(path="#genai[/references/image-edit-review-standard.md]")` whenever a candidate came from `@genai:image_edit`. Before a media call, read the applicable sections with `read(path="#genai[/references/media-calls.md]")`, then use titled `run(scope="tool")` with `command="@genai:image_generate"` or `command="@genai:image_edit"` and the resolved request object encoded as a JSON string in `args`. Judge requested-change success and first-glance perceptual fidelity by default; do not convert normal generative redraw, micro-detail drift, or seam mismatch into a failure unless a named technical invariant requires strict correspondence.

1. Analyze the source with `analyze(images={{path=<SOURCE>, detail="original"}}, analysis_prompt="Extract task-relevant visible source facts, controls, and uncertainty for reverse engineering.", max_steps=1)`.
2. Generate a candidate. For a direct source/candidate comparison, call `analyze(images={{path=<SOURCE>, target_long_edge=760},{path=<CANDIDATE>, target_long_edge=760}}, analysis_prompt="Image 1 is the source and Image 2 is the candidate. Compare them jointly using image-edit-review-standard; report candidate path, passed controls, concrete mismatches, uncertainty, and next prompt changes.", max_steps=1)`. Keep an existing labeled contact sheet only when its layout or annotations are required evidence.
3. Use each returned report directly. Do not duplicate it with parent `report` or manage image TTL through `keep`.
4. Preserve source and candidate paths independently so later rounds can analyze the current ordered pair directly.

Required direct-comparison order:

```text
source analysis → generate candidate → jointly analyze ordered source and candidate images → use returned report
```

| Rule type | Location |
|---|---|
| General prompt principle | `references/craft.md` |
| New category/routing | `references/gallery-index.md` |
| Category schema/pitfall | `references/categories/*.md` |
| Reverse workflow improvement | `references/reverse-engineering.md` |
| Role checklist | `references/roles.md` |

## Response Template

For “reverse this case”, output:

```text
### Visual Type
...

### Visible Structure
- Canvas/aspect: ...
- Layout: ...
- Subject: ...
- Copy/text: ...
- Style: ...

### Prompt-as-Code Schema
...

### Reusable Rules
1. ...
2. ...

### Pitfalls
- ...

### genai Call Advice
- call target: @genai:image_generate / @genai:image_edit
- requested_size: ...
- provider constraints: ...
```

For requests to persist rules into genai, first state target file and reason, then patch the relevant reference. Do not put a single case transcript into `SKILL.md`.

## Quality Gate

Only persist reusable, scoped rules supported by the observed case and consistent with `craft.md`. State untested limits; one successful image is not evidence of a universal model rule or fixed quality/latency improvement. Local transport constraints belong in `preflight.md`, not copied into every case rule.
