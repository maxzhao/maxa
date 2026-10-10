# Image Prompt Craft

Purpose: turn user intent into maintainable, self-contained prompts for `@genai:image_generate` and `@genai:image_edit`. This is the shared prompt-writing contract for ordinary calls, categories, templates, iterative edits, and generated intermediates in specialized workflows.

## Source And Scope

Source: [OpenAI Image prompting](https://developers.openai.com/api/docs/guides/image-prompting), verified 2026-09-10. This handbook extracts shared techniques from Prompting fundamentals, Generate images, Edit images, Refine an image across turns, and Check the result; it does not distinguish models or prescribe a model-specific mode.

- Exact text, identity, geometry, and file-format correctness require inspection; prompting is not a deterministic guarantee.
- `preflight.md` owns request-setting guidance, GenAI public-field translation and current runtime limitations. A prompt cannot enable a rejected API capability.
- Category briefs and templates are Maxa task adaptations, not additional OpenAI requirements. Examples demonstrate techniques, not mandatory content or syntax.
- Specialized geometry, compositing, data, permission, cost and acceptance contracts remain binding within their named scope. Do not generalize one provider's limitation to every image-generation backend.
- Do not copy model-specific legacy API examples, whole external prompts/assets, or fictional example data into a deliverable.

## Preserve The User's Intent

- For a detailed request, organize the existing requirements without adding creative requirements. For a broad request, add only useful intended-use, framing, layout, or visible scene detail supported by the goal.
- Do not invent characters, props, brands, slogans, palettes, story beats, product features, metrics, citations, or side-specific placement merely to fill a template.
- Preserve required text, data, panel counts, and scientific relationships. Do not silently shorten copy, remove modules, or simplify facts to make generation easier. Offer layout changes or deterministic text/vector composition when fidelity needs another method.
- Prefer editable SVG/vector/code for an editable-source deliverable. Generated UI, logos, figures, and slides are raster previews, not HTML/CSS, SVG, selectable text, structured charts, or PPTX.

## Prompting Fundamentals

1. **Define the result.** Name the subject and intended use: photograph, advertisement, interface preview, diagram, slide, character sheet, or other requested asset. Include composition, orientation/aspect ratio, framing, and placement constraints when they matter. For complex tasks, labeled scene, subject, details, and constraints sections help maintenance.
2. **Choose a readable format.** Short instructions, paragraphs, tags, labeled sections, and JSON-like briefs can express the same intent. Choose the smallest format that keeps interacting requirements clear; no fixed opening order, field list, special syntax, or verbosity is required. Prompt structure is not an API schema.
3. **Describe visible details.** Specify relevant material, lighting, color, texture, scale, atmosphere, and visual medium. Say “photorealistic” or “real photograph” when that is the goal. Camera/lens specifications are appearance cues, not guaranteed physical simulation. Ground cinematic, wide, rainy, low-light, or neon scenes in visible conditions rather than mood adjectives alone.
4. **Specify people and actions.** When important, state body framing, relative scale, gaze, pose, and interaction with objects; include feet or hands explicitly if required. Define facial/character identity and product geometry that later edits must preserve.
5. **Specify exact text.** Quote each required string, including Chinese copy, labels, numbers, units, and buttons. State placement, typography, and occurrence count when important. Spell unusual or brand-critical words letter by letter if useful. Exclude extra text and check spelling, legibility, and unintended duplicates. For small text, dense information, or multiple fonts, compare supported medium/high settings via `preflight.md`; prose about crispness does not replace API quality settings.
6. **Separate changes from constraints.** In edits, name what changes and what stays: identity, proportions, geometry, labels, layout, lighting, and background. For precise local edits include protected saturation, contrast, arrows, camera angle, and surrounding objects when relevant. State specific unwanted additions, text, logos, or watermarks rather than a generic prohibition list.
7. **Assign reference roles.** Identify inputs by number and visible purpose: edit target, subject, style, clothing, product/label, composition, or background. Explain which elements move where and how they combine. Style-only references are not necessarily edit targets.
8. **Iterate deliberately.** Inspect the output, pass the selected previous output as the next edit input, request one focused change, and restate critical preservation constraints. Compare results before adding instructions. Repeated edits can drift; use a reusable character/product reference when consistency spans scenes.

## Generation Briefs By Goal

Use `gallery-index.md` for one relevant category, or at most two for a mixed deliverable. Keep these as task-specific checklists, not a requirement to elaborate every simple request.

| Goal | Prompt controls and acceptance |
| --- | --- |
| Photography | Subject/action, framing, real-world light, material/skin texture, natural color and retouching boundary. Verify plausibility; a lens name alone does not establish realism. |
| Process / infographic | Audience, process and lesson objective, required components, flow, arrows, legend, labels and factual relationships. Verify semantics as well as appearance. |
| Science / education | Instructional brief, audience, scientific constraints, named components and exclusions, consistent visual system, whitespace and readable labels. Supply verified data, units and relationships. |
| UI preview | Describe a product as if shipped: real interface elements, layout, hierarchy, spacing, navigation and actual copy/data. Avoid concept-art language when a usable-looking interface is wanted. |
| Slide / diagram / chart | Exact raster deliverable, canvas, hierarchy, real text/numbers/axes/legend, visual language and practical spacing. Do not reuse fictional sample figures or citations as facts. |
| Poster / ad / card | Audience, scene and material/light treatment, exact quoted copy, typography, placement and repetition limits. Add no unrelated slogans, logos, or sponsor claims. |
| Logo / merchandise | Original design, brand/shape constraints, strong silhouette and negative space for small/large use; packaging materials and label clarity where relevant. Raster “vector-like” is not editable vector. |
| Historical scene | Place and date plus required period details. Inspect clothing, staging and surroundings rather than assuming inferred context is accurate. |
| Comic / storyboard | Concrete action-focused visual beats, one per requested panel; panel count/reading order and shared identity/style. Preserve requested dialogue rather than imposing a blanket no-text rule. |
| Character / sprite series | Establish reusable appearance, proportions, outfit and palette reference; repeat defining details while changing scene/action, and inspect frame-to-frame consistency. |

## Image Editing

An optional structure for interacting requirements:

```text
Image 1: edit target and reference for [identity/layout/geometry].
Image 2: reference for [specific style/clothing/subject/background], not [other role].
Change only [visible target and requested transformation].
Preserve [task-relevant identity, labels, layout, lighting, colors, surrounding objects].
Combine [element from input] with [destination], matching [scale/perspective/light/shadows].
Do not add or alter [specific excluded content].
```

For a simple edit, a short instruction naming the target and preserved context is sufficient. Do not force the complete scaffold into every call.

| Edit | Required distinction |
| --- | --- |
| Translate text | Specify target language and any required translations; replace text only, preserve design and layout. Check accuracy and words left in the source language. |
| Transfer style | Identify the reference's palette/texture/medium separately from the requested subject. State whether the result is a new image or an edit of an existing target. |
| Clothing change | Preserve face, expression, skin tone, hair, body proportions and pose; fit only the supplied garments naturally and match existing light/shadows. |
| Multi-reference composite | Specify source element, destination, placement, scale and perspective; match lighting/contact shadows and preserve background context. |
| Sketch to realism | Preserve layout, proportions and perspective; add plausible materials/light consistent with the sketch, without unrequested elements/text. |
| Remove / replace an object | Name the object and location; restore or match the surrounding background while keeping camera, lighting, other objects and subject unchanged. |

### Context Isolation And Iteration

GenAI calls supply the prompt and listed images, not the Agent's conversation history. “Same style as before” is meaningful only when the necessary reference is supplied. Translate internal filenames, phase names, layer IDs, review status, and task jargon into visible image roles and relationships; do not send unexplained codes.

`iterative-workflows.md` owns candidate state, previous-output chaining and repair records. `media-calls.md` owns the local cost/approval limit; it is not a model limitation or an OpenAI-mandated iteration count.

### Exact Preservation Boundary

Request the full preservation contract even though generation is not deterministic. Inspect each edit for unintended changes. When a region must remain **pixel-identical**, composite an approved edit into the original with a deterministic region/mask operation and verify the protected pixels; additional prompt emphasis is not sufficient. User-provided masks follow GenAI's local-mask contract in `preflight.md`, not an assumed model guarantee.

`image-edit-review-standard.md` owns comparison evidence: first-glance identity for ordinary visual variation, full enforcement of named text/geometry/data/technical invariants. A subtle but wrong digit or label does not pass merely because the whole image looks similar.

## Acceptance And Repair

Before calling, check applicable controls, input roles, exact text/data, preserved content, exclusions, and separate API settings through `preflight.md`. Prompt-only work returns a self-contained prompt plus relevant parameter advice without generating or claiming visual acceptance.

After generation/editing follow `media-calls.md` and the selected category/workflow:

- Verify required wording, spelling, occurrence count and legibility; check diagram labels, numbers and relationships.
- Verify identities, product shapes, labels and reference details; check that only requested edits occurred.
- Verify saved dimensions and format when required, not just tool success.
- Repair the observed defect without weakening required content. Clarify layout or text placement, narrow an edit, restate a defining reference constraint, or test a supported quality setting when relevant. Preserve the selected baseline and change one factor at a time.
- When evaluating prompt or setting changes, use `preflight.md`'s controlled comparisons, including complete edit sequences, rather than claiming quality, speed or cost improvements from a single example.
- Unmet deliverable requirements remain explicit; do not claim final acceptance without the required evidence.
