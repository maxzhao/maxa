# Business Visual

Use for SWOT cards, strategy one-pagers, executive dashboards, business infographics, and consulting slide visuals. Keep the result deliverable-ready, not decorative tech art.

## Use Cases

- SWOT / 2x2 matrix / strategy one-pager.
- Executive dashboard, board update visual, KPI summary.
- Business infographic, market landscape, competitive map.
- Consulting slide visual, operating model, go-to-market overview.
- Business report cover, one-page summary, social business graphic.

Shared image generation/editing techniques are owned by `references/craft.md`; the schema and example below are optional domain briefs. Use `references/preflight.md` for runtime-dependent request settings and exact-size handling, separately from visual prompt text.

## Mini Schema

```text
Create a business visual deliverable for [audience/use_case].
Deliverable: [SWOT card / strategy one-pager / executive dashboard / business infographic / consulting slide visual].
Canvas: [16:9 landscape / square card / portrait report page].
Business context: [company/product/market], decision goal: [what the audience should understand].
Layout: [2x2 matrix / KPI cards / timeline / funnel / map / dashboard].
Exact text: [title, section labels, short metrics, callouts].
Data policy: use only provided metrics; use placeholders if values are unknown.
Style: [consulting deck / executive memo / modern SaaS dashboard], restrained palette.
Constraints: deliverable-ready, short precise labels, no decorative tech-art, no invented claims.
```

## Required Controls

- Audience and use: CEO, board, sales team, investor, internal review.
- Deliverable type: SWOT, one-pager, dashboard, infographic, consulting visual.
- Decision goal: what the reader should understand.
- Metrics, labels, titles: short and exact; values must come from user or be marked placeholders.
- Layout: 2x2, cards, timeline, funnel, landscape map, dashboard grid.

## Recommended Sizes

- 16:9 business slide / consulting visual: `2048x1152`.
- Executive dashboard: `1536x1024` or `2048x1152`.
- Square strategy/social card: `1024x1024` or `2048x2048`.
- Portrait one-pager: `1024x1536` or `2160x3840`.

## Pitfalls

- Business visuals should look like deliverables: grid, titles, metrics, legends, whitespace.
- Preserve supplied copy, values, and required blocks. For dense content, improve grouping, typography, and spacing; shorten or split content only with user authorization.
- Do not invent revenue, market share, customer logos, funding, certifications, or conclusions.
- Do not turn SWOT/strategy into abstract art. Use consulting deck, board memo, or executive memo style.
- Unknown data must be explicit placeholders such as `TBD`, `Index 100`, or `Sample metric`.

## Visual Verification

- Check title, section labels, KPI, matrix axes, legends, and callouts for readability.
- Check layout matches SWOT/one-pager/dashboard/funnel/timeline instead of abstract tech background.
- Check for invented revenue, market share, customer logos, funding, certifications, or unsupported conclusions.
- Check unknown data appears as placeholders.

## Prompt Skeleton

The metrics below are fictional design inputs, not evidence or a source for real business claims.

```text
Create a landscape executive strategy one-pager for a fictional B2B SaaS company named "MetricFlow".
Audience: leadership team quarterly review. Decision goal: clarify the next-quarter go-to-market focus.
Layout: 16:9 consulting slide visual with a clear title, three KPI cards across the top, a 2x2 priority matrix in the center, and a bottom action strip.
Exact title: "Q3 Growth Focus".
KPI cards: "Pipeline Coverage 3.2x", "Net Revenue Retention 118%", "Enterprise Win Rate 31%".
Matrix labels: "High Impact", "Low Impact", "Low Effort", "High Effort".
Action strip: "Focus: enterprise onboarding, partner enablement, usage-based expansion".
Style: executive-ready consulting deck, white background, deep blue and slate palette, crisp grid, precise labels, restrained icons. Avoid decorative tech-art, fake customer logos, invented claims, and unreadable microtext.
```
