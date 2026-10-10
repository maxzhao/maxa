# GenAI Role Checklists

Use these optional task-specific checklists inside one Agent under `craft.md`'s shared prompting contract. They do not impose special syntax or prove backend capability. Do not invoke subagents only because roles are listed. Select relevant roles for prompt design, visual QA, or case reverse engineering; do not write role names into the final image prompt unless requested.

## Routing

| Task | Roles |
|---|---|
| General text-to-image | Prompt Architect |
| UI/App/Web/Dashboard | UI Mockup Designer + Prompt Architect |
| App Store / Google Play upload art | App Store Screenshot Producer + UI Mockup Designer |
| Scientific figure / method figure | Scientific Figure Designer + Infographic Designer |
| PPT/slide/pitch deck | Presentation Art Director + Business Visual Consultant |
| Storyboard / I2V visual seed | Storyboard Director + Character/Continuity Reviewer |
| Logo / brand identity | Brand Identity Designer + Typography/Poster Designer |
| Business one-pager / dashboard / SWOT | Business Visual Consultant + Infographic Designer |
| Infographic / technical explanation | Infographic Designer + Visual Taxonomist |
| Poster / cover / Chinese title | Typography/Poster Designer + Prompt Architect |
| Reference edit / style transfer | Reference Edit Specialist + Prompt Architect |
| Post-generation visual verification | Visual QA Reviewer + corresponding category role |
| Case reverse engineering / rule capture | Reverse Engineer + Visual Taxonomist + corresponding category role |

## Role Cards

### Prompt Architect

Use when: turning user intent into a high-quality prompt.

- Focus: output type, canvas, layout, subject, style, exact text, constraints, and configured image-mode parameter compatibility.
- Check: required result and visible details are clear in a maintainable format; quote exact text with placement and occurrence count where relevant; separate API settings through `preflight.md` rather than requiring a fixed prompt order.
- Failures: mood adjectives without necessary visible cues; missing task-relevant composition; altered user copy/data; legacy transport settings mistaken for universal requirements.

### Visual QA Reviewer

Use when: `@genai:image_generate` / `@genai:image_edit` returned images for text/layout/brand/reference/scientific/UI/PPT/App Store/business/multipanel/production tasks.

- Focus: actual match to user goal and final prompt, not API success; exact text, module/panel count, layout regions, invariants, brand/subject consistency; repair vs report decision.
- Check: call `analyze(images={{path=..., target_long_edge=760}}, analysis_prompt="Verify prompt adherence, text accuracy, layout correctness, subject consistency, edit preservation, and uncertainty; report path, passes, and issues.", max_steps=1)`; use a separate explicit `region` analysis for small text/Logo/UI when needed and consume each returned report directly. For `image_edit`, apply `references/image-edit-review-standard.md`: complete-view first-glance identity and requested-change success are primary; accept normal generative redraw and do not demand 1:1 pixels or exact seams unless a named technical invariant requires them.
- Failures: returning only path; API success with unreadable text or drift; claiming completion despite severe issues; more than 1 automatic repair by default.

### Visual Taxonomist

Use when: choosing category/template or extracting reusable visual rules.

- Focus: primary/secondary category; composition, medium, palette, lighting, material, text density, information hierarchy; mixed categories.
- Check: closest `references/categories/*.md`; read 1 category, or 2 only for mixed cases; distinguish reusable rule vs one-case detail.
- Failures: treating all visuals as posters; ignoring hierarchy/text strategy; using style words as full rules.

### UI Mockup Designer

Use when: App, Web, dashboard, design system, product UI screenshot.

- Focus: product/page/platform, information architecture, components, real copy/data, spacing/typography/icon alignment/palette.
- Check: product and page named; device/window specified; header/cards/charts/tables/nav/list regions; real numbers/list items; production-quality mockup requirement.
- Failures: “modern clean UI” only; fake text/buttons/charts; missing navigation, data, cards, or regions.

### Infographic Designer

Use when: infographic, knowledge graph, technical explanation, educational chart.

- Focus: chart type, reading path, module count, numbered arrows, legend, labels, information hierarchy.
- Check: infographic/field guide/classroom chart/system diagram type; title area, central diagram, side modules, legend; short title/explanation per module; arrow direction; no random formulas or unreadable microtext.
- Failures: too many modules/text; meaningless arrows; visually nice but unreadable information.

### Typography/Poster Designer

Use when: poster, cover, event visual, brand campaign, strong Chinese title.

- Focus: first-eye title/visual, second-eye subtitle/sell point/date/CTA, third-eye detail/texture; exact copy, hierarchy, whitespace.
- Check: quoted main title; subtitle/date/price/button/slogan listed; hero/supporting/fine-print hierarchy; no fake sponsor logos or unreadable microtext; material/light/background supports theme.
- Failures: equal-weight text blocks; random brands/sponsors; Chinese garbling.

### Reference Edit Specialist

Use when: local image edit, restyle, multi-reference fusion, iterative edit.

- Focus: separate changes from invariants; per-image roles; perceptual identity/layout/text/brand/geometry preservation under `references/image-edit-review-standard.md`; normal redraw is acceptable unless it causes a first-glance identity/task difference; `mask_path` only when explicit local mask exists; fallback if unsupported/safety failure.
- Check: what changes vs what stays; Image 1/2/3 visible roles; prompt self-contained, no stage/layer/temp-file/review jargon; preserve identity/composition/text/brand; mask only for explicit localized edits.
- Failures: “change style” causing drift; forgetting original text/layout; internal Agent terms in prompt; temporary codes instead of visible image relationships; mask misuse.

### Reverse Engineer

Use when: case image/prompt/link/generated result must become reusable genai rules.

- Focus: visual facts before interpretation; reverse prompt controls; single-case vs reusable schema; adapt to the configured image mode and genai references.
- Check: extract output type, canvas, layout, subject, style, text, constraints; identify pitfalls; state scope/counterexamples; convert old API params to current provider-compatible form.
- Failures: copying prompt without abstraction; overgeneralizing one-off details; no target category/location for rules.

### App Store Screenshot Producer

Use when: App Store / Google Play listing screenshots, device-frame compositions, benefit-first store visuals.

- Focus: upload purpose, device/safe area, screenshot sequence, real UI fidelity, short benefit headline, competitor analysis as structure only.
- Check: store/platform/device/canvas; preserve provided UI and do not invent features; one headline per screenshot; no fake awards/ratings/store badges/certifications.
- Failures: treating store art as generic UI mockup; invented app functionality/reviews; long unreadable copy.

### Scientific Figure Designer

Use when: research figure, method/pipeline diagram, cohort flow, benchmark chart, conference poster.

- Focus: figure type, modules, arrows, legend, units, panels, research semantics; output as reference/workflow sketch/style target, not final publication vector.
- Check: audience and lesson/figure objective, required components, exact labels/units, reading order and connections; preserve verified data without invented formulas or citations. Check dense labels with appropriate supported quality and readable-scale review, not a generic “follow exactly” incantation.
- Failures: “professional scientific figure” without diagram grammar; beautiful tech art without labels/units/arrows; treating raster output as final submission figure.

### Presentation Art Director

Use when: PPT, 16:9 slide, pitch deck, data slide, executive update, LinkedIn carousel cover.

- Focus: `slides_plan`, page purpose, one takeaway, canvas, title hierarchy, short bullets, metrics, visual system; sample slide before batch deck work.
- Check: generate visual/prompt, not editable pptx; one main message per slide; short title/metrics/chart labels; no copied external template text/assets.
- Failures: entire deck compressed into one collage; long paragraphs garble; batch expansion without sample confirmation.

### Storyboard Director

Use when: 4/6/9-panel storyboard, comic drama, short-video visual seed, news visualization, I2V reference.

- Focus: all panels on one canvas as visual DNA; character/wardrobe/props/setting/palette/camera consistency; storyboard as I2V reference, not motion prompt.
- Check: panel count/grid and reading order; concrete action-focused beat per panel; shared character/scene invariants. Quote requested dialogue/captions and verify them; omit them only when the requested video-seed format excludes text.
- Failures: missing reference continuity across separate calls; motion-heavy text without visible action; unreadable or unrequested comic bubbles.

### Character/Continuity Reviewer

Use when: multipanel, storyboard, character series, ads requiring identity/brand continuity.

- Focus: identity, outfit, hair, proportions, key props, color across panels; allowed vs fixed elements.
- Check: reusable character reference, defining appearance/proportions/outfit/palette repeated across scenes; panel or scene changes follow the story while protected identity stays fixed.
- Failures: changing face/clothes/props; inconsistent environment light/color grading.

### Brand Identity Designer

Use when: logo concept grid, brand identity board, app icon, wordmark/mark/lockup, touchpoint board.

- Focus: brand name/domain/audience/personality, requested palette, simple scalable marks and negative space, and the raster-concept versus final SVG/vector boundary.
- Check: logo type; exact brand spelling; no fake certifications/third-party badges/existing-brand similarity; vector needs separate tool/workflow.
- Failures: logo becomes complex illustration; misspelled/random brand; raster concept mistaken for editable vector.

### Business Visual Consultant

Use when: SWOT card, strategy one-pager, executive dashboard, business infographic, consulting slide visual.

- Focus: audience, decision goal, deliverable type, business structure, short labels/metrics, deliverable-ready visual system.
- Check: audience/goal explicit; layout as 2x2/cards/timeline/funnel/dashboard grid; only user-provided metrics or placeholders; no fake customer logos/funding/certification/unsupported conclusions.
- Failures: abstract tech background instead of business material; excessive small text; invented market data or customer logos.
