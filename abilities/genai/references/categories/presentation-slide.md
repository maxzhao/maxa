# Presentation Slide

Use for 16:9 slides, pitch deck covers, data slides, executive updates, and LinkedIn carousel covers. Inspired by PPT visual generation and business artifact workflows; this file keeps structure and pitfalls and does not promise direct pptx packaging.

## Use Cases

- Pitch deck cover, section divider, problem/solution, market, roadmap page.
- Single data slide, executive update, board memo visual.
- LinkedIn carousel cover or visually consistent sharing pages.
- Visual sample/page prompt based on existing brand or template screenshot.
- Style frame / sample slide confirmation before a complex deck.

Shared image generation/editing techniques are owned by `references/craft.md`; the schema and example below are optional domain briefs. Use `references/preflight.md` for runtime-dependent request settings and exact-size handling, separately from visual prompt text.

## Mini Schema

```text
Create a presentation slide visual for [audience/use_case].
Slides plan: [cover / sample slide / one-page data slide / carousel cover], [position in deck].
Canvas: 16:9 landscape or [carousel ratio].
Slide title: "[exact title]".
Message: [one sentence takeaway].
Layout: [hero visual / split layout / data cards / timeline / chart + callout].
Content blocks: [exact labels, short bullets, metrics].
Visual system: [brand palette], [type hierarchy], [grid], [icon/illustration style].
Constraints: executive-ready, short readable text, consistent margins, no pptx packaging promise.
```

## Required Controls

- Start with `slides_plan`: page purpose, order, and one-sentence takeaway for each needed page.
- Output scope: cover, sample slide, single-page image, carousel cover, or page prompt; do not promise full editable pptx by default.
- Canvas/ratio: default 16:9; carousel may be square or portrait.
- Exact title, short bullets, key metrics, chart labels.
- Sample strategy: for complex decks, make cover/sample first, then batch page prompts.

## Recommended Sizes

- 16:9 slide: `2048x1152` or `3840x2160`.
- LinkedIn carousel cover: `1024x1024` or `2048x2048`.
- Portrait/mobile share slide: `1024x1536` or `2160x3840`.

## Pitfalls

- Define `slides_plan`; do not turn “make a deck” into one chaotic collage.
- One main message per slide; split complex data into charts, KPI cards, and one takeaway.
- The model generates images or prompts, not editable pptx; use later PPT/Keynote/Figma workflow if needed.
- Do not copy external template text, brand assets, or paid template visuals; abstract layout/hierarchy/rhythm only.
- Preserve supplied text, metrics, citations, and required blocks. Improve grouping and typography for dense slides; split pages or shorten copy only with user authorization.

## Visual Verification

- Check slide title, subtitle, bullets, metrics, footer for accuracy/readability.
- Check 16:9/canvas, hierarchy, whitespace, grid, main message, and visual system; avoid collage.
- Check no promise or implication of editable pptx.
- For deck requests, confirm current image is cover/sample/single page and recommend confirmation before batch expansion.

## Prompt Skeleton

```text
Create a 16:9 pitch deck cover slide visual for a fictional AI analytics product named "SignalLake".
Slides plan context: this is slide 1, the cover page before problem and product demo slides.
Canvas: 16:9 landscape presentation slide.
Exact title: "SignalLake".
Subtitle: "Decision intelligence for revenue teams".
Layout: left-aligned title block, right-side abstract dashboard hero visual, small footer text "Seed pitch · 2026".
Visual system: deep navy background, electric cyan data accents, clean executive typography, generous margins, subtle grid texture.
Prioritize boardroom-ready polish, crisp readable text, strong hierarchy, and a restrained SaaS pitch aesthetic. Avoid clutter, fake customer logos, unreadable microtext, and any promise to output an editable pptx.
```
